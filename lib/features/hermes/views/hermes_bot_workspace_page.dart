import 'package:conduit_core/features/hermes/services/hermes_workspace_service.dart';

import 'dart:math' as math;
import 'dart:async';

import 'package:conduit_core/providers/host_ports.dart';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_job.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/hermes/services/hermes_pending_decision_store.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';

import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../providers/hermes_workspace.dart';
import '../providers/hermes_messages.dart';
import '../widgets/hermes_bot_avatar.dart';
import '../widgets/hermes_capability_picker.dart';
import '../widgets/hermes_message_icon.dart';
import '../widgets/hermes_visual_model_selector.dart';
import '../widgets/hermes_file_explorer.dart';
import '../widgets/hermes_message_interactions.dart';
import '../widgets/hermes_approval_card.dart';
import '../widgets/hermes_decision_card.dart';
import '../widgets/hermes_schedule_editor.dart';
import 'hermes_jobs_page.dart' show HermesScheduleCard;
import '../../chat/widgets/streaming_status_widget.dart';

void refreshHermesBot(WidgetRef ref, String profile) {
  ref.invalidate(hermesBotIdentityProvider(profile));
  ref.invalidate(hermesBotsProvider);
  ref.invalidate(hermesMessagesBotsProvider);
  ref.invalidate(hermesBotConversationsProvider);
}

Future<void> openHermesBotWorkspace(BuildContext context, HermesBot bot) =>
    Navigator.of(context).push<void>(
      MaterialPageRoute(builder: (_) => HermesBotWorkspacePage(bot: bot)),
    );

class HermesBotWorkspacePage extends ConsumerStatefulWidget {
  const HermesBotWorkspacePage({super.key, required this.bot});
  final HermesBot bot;
  @override
  ConsumerState<HermesBotWorkspacePage> createState() => _BotWorkspaceState();
}

class _BotWorkspaceState extends ConsumerState<HermesBotWorkspacePage> {
  String _tab = 'Identity';
  final _tabs = const [
    'Activity',
    'Approvals',
    'Files',
    'Schedules',
    'Identity',
  ];
  final _tabKeys = <String, GlobalKey>{};
  @override
  void initState() {
    super.initState();
    _revealSelectedTab();
  }

  void _revealSelectedTab() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final tabContext = _tabKeys[_tab]?.currentContext;
      if (tabContext != null) {
        unawaited(Scrollable.ensureVisible(tabContext, alignment: .5));
      }
    });
  }

  late final Object? _service = ref.read(hermesApiServiceProvider);
  bool get _current =>
      mounted && identical(_service, ref.read(hermesApiServiceProvider));
  HermesBot get _bot =>
      ref
          .read(hermesMessagesBotsProvider)
          .asData
          ?.value
          .where((b) => b.name == widget.bot.name)
          .firstOrNull ??
      widget.bot;

  Future<void> _edit() async {
    final identity = await ref.read(
      hermesBotIdentityProvider(widget.bot.name).future,
    );
    if (!mounted || !_current) return;
    await showCompactConfigurationSheet<Map<String, dynamic>>(
      context,
      (_) => HermesIdentityEditor(
        bot: _bot,
        description: identity['description']?.toString() ?? '',
        onSave: _save,
      ),
    );
  }

  Future<bool> _save(Map<String, dynamic> changes) async {
    final service = ref.read(hermesWorkspaceServiceProvider);
    if (service == null || !_current) return false;
    try {
      if (changes['ui_meta'] is Map) {
        final latest = await service.describeBot(widget.bot.name);
        final meta = latest['ui_meta'] is Map
            ? latest['ui_meta'] as Map
            : const {};
        final current = meta['hermes-bots'] is Map
            ? meta['hermes-bots'] as Map
            : const {};
        changes = {
          ...changes,
          'ui_meta': {
            'hermes-bots': {
              ...current,
              ...changes['ui_meta']['hermes-bots'] as Map,
            },
          },
          if (latest['ui_meta_revisions'] is Map)
            'ui_meta_expected_revisions': {
              'hermes-bots': latest['ui_meta_revisions']['hermes-bots'] ?? 0,
            },
        };
      }
      if (!mounted || !_current) return false;
      await service.configureBot(widget.bot.name, changes);
      if (mounted && _current) refreshHermesBot(ref, widget.bot.name);
      return true;
    } catch (_) {
      if (mounted && _current) {
        AdaptiveSnackBar.show(
          context,
          message: 'Could not save. Refresh and try again.',
        );
      }
      return false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final roster =
        ref.watch(hermesMessagesBotsProvider).asData?.value ??
        const <HermesBot>[];
    final bot =
        roster.where((b) => b.name == widget.bot.name).firstOrNull ??
        widget.bot;
    final same = identical(_service, ref.watch(hermesApiServiceProvider));
    return AdaptiveScaffold(
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 4, 8, 0),
              child: Row(
                children: [
                  CompactIconAction(
                    tooltip: 'Back',
                    icon: const Icon(HermesMessageIcons.back),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const SizedBox(width: 8),
                  Semantics(
                    label: 'Edit ${bot.title}',
                    button: true,
                    child: InkWell(
                      onTap: same ? _edit : null,
                      borderRadius: BorderRadius.circular(24),
                      child: SizedBox(
                        width: 64,
                        height: 64,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            HermesBotAvatar(
                              size: 48,
                              label: bot.title,
                              shape: bot.avatarShape,
                              color: bot.avatarColor,
                              icon: bot.icon,
                            ),
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: CircleAvatar(
                                radius: 12,
                                backgroundColor: context
                                    .conduitTheme
                                    .surfaceContainerHighest,
                                child: Icon(
                                  HermesMessageIcons.edit,
                                  color: context.conduitTheme.textPrimary,
                                  size: 14,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      bot.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                  ),
                ],
              ),
            ),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(
                children: [
                  for (final tab in _tabs)
                    Semantics(
                      key: _tabKeys.putIfAbsent(tab, () => GlobalKey()),
                      selected: _tab == tab,
                      child: DecoratedBox(
                        key: ValueKey('bot-workspace-tab-$tab'),
                        decoration: BoxDecoration(
                          border: Border(
                            bottom: BorderSide(
                              color: _tab == tab
                                  ? context.conduitTheme.textPrimary
                                  : context.conduitTheme.dividerColor,
                              width: _tab == tab ? 2 : 1,
                            ),
                          ),
                        ),
                        child: TextButton(
                          onPressed: () {
                            setState(() => _tab = tab);
                            _revealSelectedTab();
                          },
                          style: TextButton.styleFrom(
                            minimumSize: const Size(48, 48),
                            foregroundColor: context.conduitTheme.textPrimary,
                          ),
                          child: Text(tab),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: !same
                  ? const Center(
                      child: Text('Connection changed. Reopen this bot.'),
                    )
                  : switch (_tab) {
                      'Identity' => _identity(bot),
                      'Files' => _files(bot),
                      'Schedules' => _BotSchedules(profile: bot.name),
                      'Activity' => _BotActivity(bot: bot),
                      _ => _approvals(bot),
                    },
            ),
          ],
        ),
      ),
    );
  }

  Widget _identity(HermesBot bot) => ref
      .watch(hermesBotIdentityProvider(bot.name))
      .when(
        loading: () => const Center(child: AdaptiveProgressIndicator()),
        error: (_, _) =>
            _retry(() => ref.invalidate(hermesBotIdentityProvider(bot.name))),
        data: (data) => ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          children: [
            CompactContentRow(
              surface: true,
              leading: const Icon(Icons.psychology_outlined),
              title: const Text('SOUL'),
              subtitle: const Text('Personality & instructions'),
              trailing: const Icon(HermesMessageIcons.next, size: 16),
              onTap: () => _editSoul(data),
            ),
            const SizedBox(height: 8),
            CompactContentRow(
              surface: true,
              leading: const Icon(Icons.auto_stories_outlined),
              title: const Text('Memory'),
              trailing: const Icon(HermesMessageIcons.next, size: 16),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute(
                  builder: (_) => _BotMemoryPage(profile: bot.name),
                ),
              ),
            ),
            const SizedBox(height: 8),
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 16),
              title: const Text('Advanced'),
              children: [
                _advancedRow(
                  'Model',
                  _modelValue(data),
                  Icons.memory_outlined,
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          _BotModelPage(profile: bot.name, identity: data),
                    ),
                  ),
                ),
                for (final entry in [
                  ('Skills', 'skills', Icons.auto_awesome_outlined),
                  ('Tools', 'toolsets', Icons.build_outlined),
                  ('Connectors', 'mcp_servers', Icons.hub_outlined),
                ])
                  _advancedRow(
                    entry.$1,
                    _enabledCount(data[entry.$2]),
                    entry.$3,
                    () => _capabilities(bot, data, entry.$1, entry.$2),
                  ),
                _advancedRow(
                  'Plugins',
                  '',
                  Icons.extension_outlined,
                  () => Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => _BotPlugins(profile: bot.name),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      );
  Widget _advancedRow(
    String name,
    String value,
    IconData icon,
    VoidCallback onTap,
  ) => CompactContentRow(
    leading: Icon(icon, size: 20),
    title: Text(name),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (value.isNotEmpty)
          Text(value, style: Theme.of(context).textTheme.bodySmall),
        const SizedBox(width: 8),
        const Icon(HermesMessageIcons.next, size: 16),
      ],
    ),
    onTap: onTap,
  );
  String _modelValue(Map<String, dynamic> data) {
    final model = data['model'];
    return model is Map &&
            model['default'] is String &&
            (model['default'] as String).isNotEmpty
        ? model['default'] as String
        : 'Default';
  }

  String _enabledCount(Object? data) => data is List
      ? '${data.where((r) => r is Map && r['enabled'] != false).length} enabled'
      : '';
  Future<void> _editSoul(Map<String, dynamic> data) async {
    final original = data['soul']?.toString() ?? '';
    await showCompactConfigurationSheet<String>(
      context,
      (_) => _TextEditor(
        title: 'SOUL',
        content: original,
        help: 'Personality and standing instructions for this bot.',
        limit: 16000,
        onSave: (content) async {
          if (!_current) return false;
          final latest = await ref
              .read(hermesWorkspaceServiceProvider)!
              .describeBot(widget.bot.name);
          if (!_current || latest['soul'] != data['soul']) return false;
          return _save({'soul': content});
        },
      ),
    );
  }

  Future<void> _capabilities(
    HermesBot bot,
    Map<String, dynamic> data,
    String title,
    String key,
  ) async {
    final list = data[key] is List
        ? [
            for (final r in data[key])
              if (r is Map) Map<String, dynamic>.from(r),
          ]
        : <Map<String, dynamic>>[];
    final selected = await showCompactConfigurationSheet<Set<String>>(
      context,
      (_) => HermesCapabilityPicker(title: title, entries: list),
    );
    if (selected == null || !_current) return;
    await _save({
      switch (key) {
        'skills' => 'disabled_skills',
        'toolsets' => 'enabled_toolsets',
        _ => 'enabled_mcp_servers',
      }: key == 'skills'
          ? [
              for (final row in list)
                if (!selected.contains(row['name'])) row['name'],
            ]
          : selected.toList(),
    });
  }

  Widget _files(HermesBot bot) => ref
      .watch(hermesBotWorkspaceProvider(bot.name))
      .when(
        loading: () => const Center(child: AdaptiveProgressIndicator()),
        error: (error, _) => error is HermesWorkspaceMissing
            ? Center(
                child: FilledButton(
                  onPressed: () async {
                    final service = ref.read(hermesWorkspaceServiceProvider);
                    if (service == null) return;
                    try {
                      await service.initializeBotWorkspace(bot.name);
                      if (mounted && _current) {
                        ref.invalidate(hermesBotWorkspaceProvider(bot.name));
                      }
                    } catch (_) {
                      if (mounted) {
                        AdaptiveSnackBar.show(
                          context,
                          message: 'Could not create the bot’s folder.',
                        );
                      }
                    }
                  },
                  child: const Text('Set up files'),
                ),
              )
            : _retry(
                () => ref.invalidate(hermesBotWorkspaceProvider(bot.name)),
              ),
        data: (root) => Column(
          children: [
            CompactContentRow(
              title: const Text('Folder'),
              subtitle: Text(
                root,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              trailing: const Icon(HermesMessageIcons.edit, size: 18),
              onTap: () async {
                final path = await showCompactConfigurationSheet<String>(
                  context,
                  (_) => _TextEditor(
                    title: 'Folder',
                    content: root,
                    multiline: false,
                    help: 'Folder on the Hermes server. SOUL and memory stay in the bot’s profile.',
                  ),
                );
                if (path == null || !_current) return;
                try {
                  await ref
                      .read(hermesWorkspaceServiceProvider)!
                      .setBotWorkspace(bot.name, path.trim());
                  if (mounted && _current) {
                    ref.invalidate(hermesBotWorkspaceProvider(bot.name));
                  }
                } catch (_) {
                  if (mounted && _current) {
                    AdaptiveSnackBar.show(
                      context,
                      message: 'Could not open that folder.',
                    );
                  }
                }
              },
            ),
            Expanded(
              child: HermesScopedFilesArea(root: root, profile: bot.name),
            ),
          ],
        ),
      );
  Widget _approvals(HermesBot bot) {
    final active = ref.watch(activeConversationProvider);
    final session = bot.chatSessionId;
    final messages = active?.metadata['hermesSessionId'] == session
        ? ref.watch(chatMessagesProvider)
        : const <ChatMessage>[];
    final prompts = messages
        .where(
          (m) =>
              m.metadata?['hermesApproval'] is Map ||
              m.metadata?['hermesDecision'] is Map,
        )
        .toList();
    if (prompts.isEmpty) return _BotRequests(profile: bot.name);
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        for (final message in prompts)
          HermesComposerPromptOverlay(
            message: message,
            presentation: HermesPromptPresentation.inlineMessage,
          ),
      ],
    );
  }

  Widget _retry(VoidCallback retry) => Center(
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Could not load this section.'),
        TextButton(onPressed: retry, child: const Text('Retry')),
      ],
    ),
  );
}

class _BotActivity extends ConsumerWidget {
  const _BotActivity({required this.bot});
  final HermesBot bot;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final active = ref.watch(activeConversationProvider);
    final live = active?.metadata['hermesSessionId'] == bot.chatSessionId
        ? ref.watch(chatMessagesProvider)
        : const <ChatMessage>[];
    final history = ref.watch(hermesBotTranscriptProvider(bot.name));
    if (live.isEmpty && history.isLoading) {
      return const Center(child: AdaptiveProgressIndicator());
    }
    if (live.isEmpty && history.hasError) {
      return Center(
        child: TextButton(
          onPressed: () =>
              ref.invalidate(hermesBotTranscriptProvider(bot.name)),
          child: const Text('Retry'),
        ),
      );
    }
    final messages = live.isEmpty
        ? history.asData?.value ?? const <ChatMessage>[]
        : live;
    final updates = <ChatStatusUpdate>[
      for (final message in messages) ...message.statusHistory,
    ];
    return updates.isEmpty
        ? const Center(child: Text('No recent tool activity.'))
        : ListView(
            padding: const EdgeInsets.all(20),
            children: [
              StreamingStatusWidget(
                updates: updates.reversed.take(200).toList().reversed.toList(),
                isStreaming: messages.any((m) => m.isStreaming),
              ),
            ],
          );
  }
}

class _BotRequests extends ConsumerStatefulWidget {
  const _BotRequests({required this.profile});
  final String profile;
  @override
  ConsumerState<_BotRequests> createState() => _BotRequestsState();
}

class _BotRequestsState extends ConsumerState<_BotRequests> {
  String? _resolving;
  Future<bool> _answer(
    HermesPendingDesktopDecision request,
    String value,
  ) async {
    if (_resolving != null) return false;
    final service = ref.read(hermesMessagesBackendProvider);
    if (service == null || !request.expiresAt.isAfter(DateTime.now().toUtc())) {
      return false;
    }
    setState(() => _resolving = request.requestId);
    try {
      ref.invalidate(hermesBotRequestsProvider(widget.profile));
      final current = await ref.read(
        hermesBotRequestsProvider(widget.profile).future,
      );
      if (!mounted ||
          !identical(service, ref.read(hermesMessagesBackendProvider)) ||
          !current.any((r) => r.identity == request.identity)) {
        return false;
      }
      if (request.kind == HermesPendingDesktopDecisionKind.approval) {
        await service.resolveApprovalChoiceForSession(
          request.storedSessionId,
          approvalId: request.requestId,
          choice: value,
        );
      } else {
        await service.respondToDecision(
          runtimeId: request.runtimeId,
          storedSessionId: request.storedSessionId,
          requestId: request.requestId,
          kind: request.decisionKind!,
          value: value,
          mcpServer: request.mcpServer,
          mcpAction: request.mcpAction,
        );
      }
      if (mounted) ref.invalidate(hermesBotRequestsProvider(widget.profile));
      return true;
    } catch (_) {
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: 'Could not send your response.',
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _resolving = null);
    }
  }

  @override
  Widget build(BuildContext context) => ref
      .watch(hermesBotRequestsProvider(widget.profile))
      .when(
        loading: () => const Center(child: AdaptiveProgressIndicator()),
        error: (_, _) => Center(
          child: TextButton(
            onPressed: () =>
                ref.invalidate(hermesBotRequestsProvider(widget.profile)),
            child: const Text('Retry'),
          ),
        ),
        data: (requests) => requests.isEmpty
            ? const Center(child: Text('No requests waiting for you.'))
            : ListView(
                padding: const EdgeInsets.all(20),
                children: [
                  for (final request in requests)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child:
                          request.kind ==
                              HermesPendingDesktopDecisionKind.approval
                          ? HermesApprovalCard(
                              state: _resolving == request.requestId
                                  ? HermesApprovalState.resolving
                                  : HermesApprovalState.pending,
                              summary: request.prompt,
                              choices: request.choices,
                              onDecision: (approved) =>
                                  _answer(request, approved ? 'once' : 'deny'),
                              onChoice: (choice) => _answer(request, choice),
                            )
                          : HermesDecisionCard(
                              key: ValueKey(request.identity),
                              kind: request.decisionKind!,
                              prompt: request.prompt,
                              mcpServer: request.mcpServer,
                              mcpAction: request.mcpAction,
                              onSubmit: (value) => _answer(request, value),
                            ),
                    ),
                ],
              ),
      );
}

class _BotMemoryPage extends ConsumerStatefulWidget {
  const _BotMemoryPage({required this.profile});
  final String profile;
  @override
  ConsumerState<_BotMemoryPage> createState() => _BotMemoryState();
}

class _BotMemoryState extends ConsumerState<_BotMemoryPage> {
  bool _user = false;
  @override
  Widget build(BuildContext context) {
    final key = (profile: widget.profile, user: _user);
    final memory = ref.watch(hermesBotMemoryProvider(key));
    return AdaptiveScaffold(
      appBar: AdaptiveAppBar(
        appBar: AppBar(
          title: const Text('Memory'),
          actions: [
            CompactIconAction(
              tooltip: 'Edit memory',
              icon: const Icon(HermesMessageIcons.edit),
              onPressed: memory.asData == null
                  ? null
                  : () async {
                      final service = ref.read(hermesWorkspaceServiceProvider)!;
                      final original = memory.asData!.value;
                      await showCompactConfigurationSheet<String>(
                        context,
                        (_) => _TextEditor(
                          title: key.user ? 'About you' : 'Notes',
                          content: original,
                          help: key.user
                              ? 'What this bot remembers about you.'
                              : 'Durable facts and lessons this bot keeps.',
                          onSave: (content) async {
                            if (!mounted ||
                                !identical(
                                  service,
                                  ref.read(hermesWorkspaceServiceProvider),
                                )) {
                              return false;
                            }
                            await service.writeBotMemory(
                              widget.profile,
                              content,
                              expected: original,
                              aboutUser: key.user,
                            );
                            if (!mounted ||
                                !identical(
                                  service,
                                  ref.read(hermesWorkspaceServiceProvider),
                                )) {
                              return false;
                            }
                            ref.invalidate(hermesBotMemoryProvider(key));
                            return true;
                          },
                        ),
                      );
                    },
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Row(
            children: [
              for (final user in [false, true])
                Expanded(
                  child: Semantics(
                    selected: _user == user,
                    child: TextButton(
                      onPressed: () => setState(() => _user = user),
                      child: Text(user ? 'About you' : 'Notes'),
                    ),
                  ),
                ),
            ],
          ),
          Expanded(
            child: memory.when(
              loading: () => const Center(child: AdaptiveProgressIndicator()),
              error: (_, _) => Center(
                child: TextButton(
                  onPressed: () => ref.invalidate(hermesBotMemoryProvider(key)),
                  child: const Text('Retry'),
                ),
              ),
              data: (text) => SingleChildScrollView(
                padding: const EdgeInsets.all(20),
                child: SelectableText(
                  text.isEmpty ? 'Nothing saved yet.' : text,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TextEditor extends StatefulWidget {
  const _TextEditor({
    required this.title,
    required this.content,
    this.help,
    this.multiline = true,
    this.limit = 64000,
    this.onSave,
  });
  final String title, content;
  final String? help;
  final bool multiline;
  final int limit;
  final Future<bool> Function(String)? onSave;
  @override
  State<_TextEditor> createState() => _TextEditorState();
}

class _TextEditorState extends State<_TextEditor> {
  late final _controller = TextEditingController(text: widget.content);
  bool _saving = false;
  String? _error;
  Future<void> _submit() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.onSave?.call(_controller.text) ?? true;
      if (!mounted) return;
      if (saved) {
        Navigator.of(context).pop(_controller.text);
      } else {
        setState(() => _error = 'Could not save. Your changes are kept here.');
      }
    } catch (_) {
      if (mounted) {
        setState(() => _error = 'Could not save. Your changes are kept here.');
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      8,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(widget.title, style: Theme.of(context).textTheme.titleMedium),
        if (widget.help != null)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Text(
              widget.help!,
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ),
        Flexible(
          child: TextField(
            key: const ValueKey('bot-text-editor-input'),
            controller: _controller,
            enabled: !_saving,
            minLines: widget.multiline ? 3 : 1,
            maxLines: widget.multiline ? 14 : 1,
            maxLength: widget.limit,
            decoration: const InputDecoration(counterText: ''),
          ),
        ),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Text(
              _error!,
              style: TextStyle(color: context.conduitTheme.error),
            ),
          ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: _saving ? null : () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            const SizedBox(width: 12),
            ConduitButton(
              key: const ValueKey('bot-text-editor-save'),
              text: 'Save',
              isLoading: _saving,
              onPressed: _saving ? null : _submit,
            ),
          ],
        ),
      ],
    ),
  );
}

class _BotModelPage extends ConsumerStatefulWidget {
  const _BotModelPage({required this.profile, required this.identity});
  final String profile;
  final Map<String, dynamic> identity;
  @override
  ConsumerState<_BotModelPage> createState() => _BotModelState();
}

class _BotModelState extends ConsumerState<_BotModelPage> {
  late final _service = ref.read(hermesWorkspaceServiceProvider)!;
  late Future<List<HermesDesktopModelOption>> _models = _service.botModels(
    widget.profile,
  );
  late String _model = widget.identity['model']?['default']?.toString() ?? '',
      _provider = widget.identity['model']?['provider']?.toString() ?? '';
  bool _busy = false;
  Future<void> _pick(String model, String provider) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final changes = {'model': model, 'provider': provider};
      try {
        await _service.configureBot(widget.profile, changes);
      } on HermesBotModelConfirmation catch (confirmation) {
        if (!mounted ||
            !identical(_service, ref.read(hermesWorkspaceServiceProvider))) {
          return;
        }
        final agreed = await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: const Text('Use this model?'),
            content: Text(confirmation.message),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: const Text('Cancel'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('Use model'),
              ),
            ],
          ),
        );
        if (!mounted ||
            agreed != true ||
            !identical(_service, ref.read(hermesWorkspaceServiceProvider))) {
          return;
        }
        await _service.configureBot(widget.profile, {
          ...changes,
          'confirm_expensive_model': true,
        });
      }
      if (mounted &&
          identical(_service, ref.read(hermesWorkspaceServiceProvider))) {
        setState(() {
          _model = model;
          _provider = provider;
        });
        refreshHermesBot(ref, widget.profile);
        ref
            .read(hermesProfileRevisionsProvider.notifier)
            .changed(widget.profile);
      }
    } catch (_) {
      if (mounted) {
        AdaptiveSnackBar.show(
          context,
          message: 'Could not change the bot model.',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AdaptiveScaffold(
    appBar: AdaptiveAppBar(appBar: AppBar(title: const Text('Model'))),
    body: Padding(
      padding: const EdgeInsets.all(20),
      child: FutureBuilder(
        future: _models,
        builder: (context, snap) {
          if (!snap.hasData) {
            return snap.hasError
                ? const Text('Could not load this bot’s models.')
                : const Center(child: AdaptiveProgressIndicator());
          }
          return Column(
            children: [
              CompactModelSelector(
                model: _model.isEmpty ? 'Default' : _model,
                provider: _provider,
                selectedModelId: _model,
                currentProviderId: _provider,
                choices: hermesModelCatalogChoices(snap.data!),
                enableRecommendations: true,
                efforts: const [],
                effort: '',
                fast: false,
                fastAvailable: false,
                busy: _busy,
                onModel: (choice) => _pick(choice.id, choice.provider),
                onEffort: (_) {},
                onFast: null,
                onReset: null,
                resetLabel: 'Bot default',
              ),
              const SizedBox(height: 12),
              const Text(
                'Default for this bot. A model chosen in the chat applies only to that conversation.',
              ),
              TextButton(
                onPressed: _busy
                    ? null
                    : () async {
                        final connected = await Navigator.of(context)
                            .push<bool>(
                              MaterialPageRoute(
                                builder: (_) => _BotProviderSignInPage(
                                  profile: widget.profile,
                                ),
                              ),
                            );
                        if (context.mounted && connected == true) {
                          setState(
                            () => _models = _service.botModels(widget.profile),
                          );
                        }
                      },
                child: const Text('Connect provider'),
              ),
            ],
          );
        },
      ),
    ),
  );
}

class _BotProviderSignInPage extends ConsumerStatefulWidget {
  const _BotProviderSignInPage({required this.profile});
  final String profile;
  @override
  ConsumerState<_BotProviderSignInPage> createState() =>
      _BotProviderSignInState();
}

class _BotProviderSignInState extends ConsumerState<_BotProviderSignInPage> {
  late final _service = ref.read(hermesWorkspaceServiceProvider)!;
  late Future<List<Map<String, dynamic>>> _providers = _service
      .botOAuthProviders(widget.profile);
  @override
  Widget build(BuildContext context) => AdaptiveScaffold(
    appBar: AdaptiveAppBar(appBar: AppBar(title: const Text('Providers'))),
    body: FutureBuilder(
      future: _providers,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return Center(
            child: snapshot.hasError
                ? TextButton(
                    onPressed: () => setState(
                      () => _providers = _service.botOAuthProviders(
                        widget.profile,
                      ),
                    ),
                    child: const Text('Retry'),
                  )
                : const AdaptiveProgressIndicator(),
          );
        }
        return ListView(
          padding: const EdgeInsets.all(20),
          children: [
            for (final provider in snapshot.data!)
              CompactContentRow(
                title: Text((provider['name'] ?? provider['id']).toString()),
                subtitle: Text(
                  provider['connected'] == true
                      ? 'Connected'
                      : provider['flow'] == 'device_code'
                      ? 'Sign in'
                      : 'Sign in through Hermes on your computer',
                ),
                trailing: provider['connected'] == true
                    ? const Icon(HermesMessageIcons.check, size: 18)
                    : const Icon(HermesMessageIcons.next, size: 16),
                onTap: () async {
                  if (provider['flow'] != 'device_code') {
                    AdaptiveSnackBar.show(
                      context,
                      message:
                          'This provider uses Hermes’s desktop sign-in flow.',
                    );
                    return;
                  }
                  final connected = await showCompactConfigurationSheet<bool>(
                    context,
                    (_) => _BotOAuthFlow(
                      profile: widget.profile,
                      provider: provider['id'].toString(),
                    ),
                  );
                  if (!context.mounted ||
                      !identical(
                        _service,
                        ref.read(hermesWorkspaceServiceProvider),
                      )) {
                    return;
                  }
                  if (connected == true) {
                    ref
                        .read(hermesProfileRevisionsProvider.notifier)
                        .changed(widget.profile);
                    Navigator.of(context).pop(true);
                  }
                },
              ),
          ],
        );
      },
    ),
  );
}

class _BotOAuthFlow extends ConsumerStatefulWidget {
  const _BotOAuthFlow({required this.profile, required this.provider});
  final String profile, provider;
  @override
  ConsumerState<_BotOAuthFlow> createState() => _BotOAuthState();
}

class _BotOAuthState extends ConsumerState<_BotOAuthFlow> {
  late final _service = ref.read(hermesWorkspaceServiceProvider)!;
  late final Future<Map<String, dynamic>> _flow = _start();
  Timer? _timer;
  String? _session, _failure;
  bool _complete = false, _polling = false;
  Future<Map<String, dynamic>> _start() async {
    final flow = await _service.startBotOAuth(widget.profile, widget.provider);
    _session = flow['session_id'] as String;
    if (!mounted) {
      await _service.cancelBotOAuth(widget.profile, _session!);
      return flow;
    }
    _timer = Timer.periodic(
      Duration(seconds: flow['poll_interval'] as int),
      (_) => _poll(),
    );
    return flow;
  }

  Future<void> _poll() async {
    if (!mounted ||
        _polling ||
        _session == null ||
        !identical(_service, ref.read(hermesWorkspaceServiceProvider))) {
      return;
    }
    _polling = true;
    try {
      final status = await _service.pollBotOAuth(
        widget.profile,
        widget.provider,
        _session!,
      );
      if (!mounted) return;
      switch (status['status']) {
        case 'approved':
          _complete = true;
          _timer?.cancel();
          Navigator.of(context).pop(true);
        case 'denied':
        case 'expired':
        case 'error':
          _timer?.cancel();
          setState(
            () => _failure =
                'Sign-in did not complete. Close this window and try again.',
          );
      }
    } catch (_) {
      if (mounted) {
        _timer?.cancel();
        setState(
          () => _failure = 'Connection lost. Close this window and try again.',
        );
      }
    } finally {
      _polling = false;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    if (!_complete && _session != null) {
      unawaited(
        _service
            .cancelBotOAuth(widget.profile, _session!)
            .catchError((Object _) {}),
      );
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: FutureBuilder(
      future: _flow,
      builder: (context, snapshot) {
        if (!snapshot.hasData) {
          return snapshot.hasError
              ? const Text(
                  'Could not start sign-in. Close this window and try again.',
                )
              : const SizedBox(
                  height: 120,
                  child: Center(child: AdaptiveProgressIndicator()),
                );
        }
        final flow = snapshot.data!;
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text(
              'Sign in',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 16),
            SelectableText(
              flow['user_code'] as String,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.headlineSmall,
            ),
            const SizedBox(height: 16),
            if (_failure != null)
              Text(_failure!)
            else
              FilledButton(
                onPressed: () async {
                  final opened = await ref
                      .read(openExternalUrlProvider)
                      .open(Uri.parse(flow['verification_url'] as String));
                  if (context.mounted && !opened) {
                    AdaptiveSnackBar.show(
                      context,
                      message: 'Could not open the sign-in page.',
                    );
                  }
                },
                child: const Text('Open sign-in page'),
              ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
          ],
        );
      },
    ),
  );
}

class _BotPlugins extends ConsumerStatefulWidget {
  const _BotPlugins({required this.profile});
  final String profile;
  @override
  ConsumerState<_BotPlugins> createState() => _BotPluginsState();
}

class _BotPluginsState extends ConsumerState<_BotPlugins> {
  late final _service = ref.read(hermesWorkspaceServiceProvider)!;
  late Future<List<Map<String, dynamic>>> _plugins = _service.botPlugins(
    widget.profile,
  );
  String? _saving;
  @override
  Widget build(BuildContext context) => AdaptiveScaffold(
    appBar: AdaptiveAppBar(appBar: AppBar(title: const Text('Plugins'))),
    body: FutureBuilder(
      future: _plugins,
      builder: (context, snap) => !snap.hasData
          ? Center(
              child: snap.hasError
                  ? const Text(
                      'This Hermes version cannot manage plugins here.',
                    )
                  : const AdaptiveProgressIndicator(),
            )
          : snap.data!.isEmpty
          ? const Center(child: Text('No plugins installed for this bot.'))
          : ListView(
              padding: const EdgeInsets.all(20),
              children: [
                for (final plugin in snap.data!)
                  CheckboxListTile(
                    controlAffinity: ListTileControlAffinity.leading,
                    title: Text((plugin['name'] ?? plugin['key']).toString()),
                    value: plugin['enabled'] == true,
                    onChanged: _saving != null
                        ? null
                        : (enabled) async {
                            final key = (plugin['key'] ?? plugin['name'])
                                .toString();
                            setState(() => _saving = key);
                            try {
                              await _service.setBotPlugin(
                                widget.profile,
                                key,
                                enabled == true,
                              );
                              if (mounted) {
                                setState(
                                  () => _plugins = _service.botPlugins(
                                    widget.profile,
                                  ),
                                );
                              }
                            } catch (_) {
                              if (context.mounted) {
                                AdaptiveSnackBar.show(
                                  context,
                                  message: 'Could not change this plugin.',
                                );
                              }
                            } finally {
                              if (mounted) setState(() => _saving = null);
                            }
                          },
                  ),
              ],
            ),
    ),
  );
}

class _BotSchedules extends StatelessWidget {
  const _BotSchedules({required this.profile});
  final String profile;
  @override
  Widget build(BuildContext context) => ProviderScope(
    overrides: [
      hermesScheduleProfileProvider.overrideWithValue(profile),
      hermesJobsProvider.overrideWith(() => _BotJobsController(profile)),
      hermesJobRunsProvider.overrideWith((ref, id) async {
        final service = ref.watch(hermesApiServiceProvider);
        if (service is! HermesDesktopApiService) return const [];
        final rows = await service.listJobRuns(id, profile: profile);
        final runs = rows
            .map(HermesSessionSummary.fromJson)
            .whereType<HermesSessionSummary>()
            .take(20)
            .toList(growable: false);
        for (final run in runs) {
          service.bindBotSession(profile, run.id);
        }
        return runs;
      }),
      hermesInstalledSkillsProvider.overrideWith(
        (ref) async =>
            await ref
                .watch(hermesMessagesBackendProvider)
                ?.listProfileSkills(profile) ??
            const [],
      ),
    ],
    child: const _BotScheduleList(),
  );
}

/// Adapts profile-owned transport to the shared schedule flow.
class _BotJobsController extends HermesJobsController {
  _BotJobsController(this.profile);
  final String profile;
  String get _prefix => '[bot:$profile] ';

  @override
  Future<List<HermesJob>> build() async {
    final backend = ref.watch(hermesMessagesBackendProvider);
    final rows = await backend?.listProfileJobs(profile) ?? const [];
    return [
      for (final row in rows)
        if (HermesJob.fromJson({
              ...row,
              if (row['name'] is String)
                'name': (row['name'] as String).replaceFirst(
                  RegExp('^${RegExp.escape(_prefix)}'),
                  '',
                ),
            })
            case final HermesJob job)
          job,
    ];
  }

  Future<void> _mutate(
    String action, {
    String? id,
    Map<String, dynamic> values = const {},
  }) async {
    final service = ref.read(hermesWorkspaceServiceProvider);
    if (service == null) throw StateError('Bot schedules unavailable');
    await service.mutateBotJob(profile, id: id, action: action, values: values);
    if (!ref.mounted ||
        !identical(service, ref.read(hermesWorkspaceServiceProvider))) {
      return;
    }
    ref.invalidateSelf();
    if (id != null) ref.invalidate(hermesJobRunsProvider(id));
  }

  @override
  Future<void> create({
    required String name,
    required String prompt,
    required String schedule,
    List<String>? skills,
  }) => _mutate(
    'create',
    values: {
      'name': name.startsWith(_prefix) ? name : '$_prefix$name',
      'prompt': prompt,
      'schedule': schedule,
      'deliver': 'local',
      'skills': ?skills,
    },
  );

  @override
  Future<void> edit(
    String id, {
    String? name,
    String? prompt,
    String? schedule,
    List<String>? skills,
  }) => _mutate(
    'update',
    id: id,
    values: {
      if (name != null)
        'name': name.startsWith(_prefix) ? name : '$_prefix$name',
      'prompt': ?prompt,
      'schedule': ?schedule,
      'skills': ?skills,
    },
  );

  @override
  Future<void> setEnabled(String id, bool enabled) =>
      _mutate(enabled ? 'resume' : 'pause', id: id);
  @override
  Future<void> runNow(String id) => _mutate('run', id: id);
  @override
  Future<void> delete(String id) => _mutate('delete', id: id);
}

class _BotScheduleList extends ConsumerWidget {
  const _BotScheduleList();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final writable =
        ref.watch(hermesCapabilitiesProvider).asData?.value.jobsAdmin ?? true;
    return Column(
      children: [
        Align(
          alignment: Alignment.centerRight,
          child: CompactIconAction(
            tooltip: 'New schedule',
            icon: const Icon(HermesMessageIcons.add),
            onPressed: writable
                ? () => showHermesScheduleEditor(context)
                : null,
          ),
        ),
        Expanded(
          child: ref
              .watch(hermesJobsProvider)
              .when(
                loading: () => const Center(child: AdaptiveProgressIndicator()),
                error: (_, _) => Center(
                  child: TextButton(
                    onPressed: () => ref.invalidate(hermesJobsProvider),
                    child: const Text('Retry'),
                  ),
                ),
                data: (jobs) => jobs.isEmpty
                    ? const Center(child: Text('No schedules yet.'))
                    : ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 20),
                        children: [
                          for (final job in jobs)
                            HermesScheduleCard(
                              key: ValueKey(job.id),
                              job: job,
                              writable: writable,
                            ),
                        ],
                      ),
              ),
        ),
      ],
    );
  }
}

class HermesIdentityEditor extends StatefulWidget {
  const HermesIdentityEditor({
    super.key,
    required this.bot,
    required this.description,
    this.onSave,
  });
  final HermesBot bot;
  final String description;
  final Future<bool> Function(Map<String, dynamic>)? onSave;
  @override
  State<HermesIdentityEditor> createState() => _IdentityEditorState();
}

class _IdentityEditorState extends State<HermesIdentityEditor> {
  late final _name = TextEditingController(text: widget.bot.title),
      _purpose = TextEditingController(text: widget.description);
  late String? _icon = widget.bot.icon;
  late String _color = widget.bot.avatarColor;
  late String? _custom = colors.contains(widget.bot.avatarColor)
      ? null
      : widget.bot.avatarColor;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _name.dispose();
    _purpose.dispose();
    super.dispose();
  }

  static const colors = [
    '#8b5cf6',
    '#5b9de9',
    '#5bbf98',
    '#edbd62',
    '#e77d93',
    '#94a0b8',
  ];
  @override
  Widget build(BuildContext context) => Padding(
    padding: EdgeInsets.fromLTRB(
      20,
      8,
      20,
      MediaQuery.viewInsetsOf(context).bottom + 20,
    ),
    child: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            key: const ValueKey('bot-identity-name'),
            controller: _name,
            enabled: !_saving,
            maxLength: 256,
            decoration: const InputDecoration(
              labelText: 'Name',
              counterText: '',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            key: const ValueKey('bot-identity-purpose'),
            controller: _purpose,
            enabled: !_saving,
            minLines: 1,
            maxLines: 5,
            maxLength: 5000,
            decoration: const InputDecoration(
              labelText: 'Purpose',
              counterText: '',
            ),
          ),
          const SizedBox(height: 16),
          const Text('Icon'),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final name in [
                  'bot',
                  'research',
                  'code',
                  'brain',
                  'globe',
                  'folder',
                ])
                  Semantics(
                    label: name,
                    selected: (_icon ?? 'bot') == name,
                    button: true,
                    enabled: !_saving,
                    child: InkWell(
                      key: ValueKey('bot-identity-icon-$name'),
                      onTap: _saving
                          ? null
                          : () => setState(() => _icon = name),
                      borderRadius: BorderRadius.circular(12),
                      child: Container(
                        width: 56,
                        height: 56,
                        decoration: BoxDecoration(
                          color: (_icon ?? 'bot') == name
                              ? context.conduitTheme.surfaceContainerHighest
                              : null,
                          borderRadius: BorderRadius.circular(12),
                          border: Border.all(
                            color: (_icon ?? 'bot') == name
                                ? context.conduitTheme.inputBorderFocused
                                : Colors.transparent,
                            width: 2,
                          ),
                        ),
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            HermesBotAvatar(
                              size: 34,
                              label: name,
                              shape: 'circle',
                              color: _color,
                              icon: name,
                            ),
                            if ((_icon ?? 'bot') == name)
                              PositionedDirectional(
                                end: 1,
                                bottom: 1,
                                child: Icon(
                                  HermesMessageIcons.check,
                                  key: ValueKey(
                                    'bot-identity-icon-check-$name',
                                  ),
                                  size: 16,
                                  color: context.conduitTheme.textPrimary,
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          const Text('Color'),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final color in colors) _swatch(color),
                Semantics(
                  label: 'Custom color',
                  selected: _custom != null && _color == _custom,
                  button: true,
                  enabled: !_saving,
                  child: InkWell(
                    onTap: _saving
                        ? null
                        : () async {
                            final color =
                                await showCompactConfigurationSheet<String>(
                                  context,
                                  (_) =>
                                      _CustomColor(initial: _custom ?? _color),
                                );
                            if (mounted && color != null) {
                              setState(() {
                                _custom = color;
                                _color = color;
                              });
                            }
                          },
                    child: SizedBox(
                      width: 48,
                      height: 48,
                      child: Center(
                        child: CircleAvatar(
                          radius: 15,
                          backgroundColor: _hexColor(_custom ?? '#ffffff'),
                          child: Icon(
                            HermesMessageIcons.edit,
                            size: 16,
                            color:
                                _hexColor(_custom ?? '#ffffff')
                                        .computeLuminance() >
                                    .4
                                ? Colors.black
                                : Colors.white,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 12),
              child: Text(
                _error!,
                style: TextStyle(color: context.conduitTheme.error),
              ),
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: _saving ? null : () => Navigator.of(context).pop(),
                child: const Text('Cancel'),
              ),
              const SizedBox(width: 12),
              ConduitButton(
                key: const ValueKey('bot-identity-save'),
                text: 'Save',
                isLoading: _saving,
                onPressed: _saving
                    ? null
                    : () async {
                        if (_name.text.trim().isEmpty) return;
                        final draft = <String, dynamic>{
                          'description': _purpose.text.trim(),
                          'ui_meta': {
                            'hermes-bots': {
                              'title': _name.text.trim(),
                              'color': _color,
                              'conduitIcon': _icon,
                            },
                          },
                        };
                        setState(() {
                          _saving = true;
                          _error = null;
                        });
                        try {
                          final saved =
                              await widget.onSave?.call(draft) ?? true;
                          if (!context.mounted) return;
                          if (saved) {
                            Navigator.of(context).pop(draft);
                          } else {
                            setState(
                              () => _error =
                                  'Could not save. Your changes are kept here.',
                            );
                          }
                        } catch (_) {
                          if (mounted) {
                            setState(
                              () => _error =
                                  'Could not save. Your changes are kept here.',
                            );
                          }
                        } finally {
                          if (mounted) setState(() => _saving = false);
                        }
                      },
              ),
            ],
          ),
        ],
      ),
    ),
  );
  Widget _swatch(String color) => Semantics(
    label: color,
    selected: _color == color,
    button: true,
    enabled: !_saving,
    child: InkWell(
      onTap: _saving ? null : () => setState(() => _color = color),
      child: SizedBox(
        width: 48,
        height: 48,
        child: Center(
          child: CircleAvatar(
            radius: 15,
            backgroundColor: _hexColor(color),
            child: _color == color
                ? Icon(
                    HermesMessageIcons.check,
                    size: 18,
                    color: _hexColor(color).computeLuminance() > .4
                        ? Colors.black
                        : Colors.white,
                  )
                : null,
          ),
        ),
      ),
    ),
  );
}

Color _hexColor(String hex) => Color(
  0xff000000 | (int.tryParse(hex.replaceFirst('#', ''), radix: 16) ?? 0x8b5cf6),
);

class _CustomColor extends StatefulWidget {
  const _CustomColor({required this.initial});
  final String initial;
  @override
  State<_CustomColor> createState() => _CustomColorState();
}

class _CustomColorState extends State<_CustomColor> {
  late HSVColor _hsv = HSVColor.fromColor(_hexColor(widget.initial));
  late final _hex = TextEditingController(text: widget.initial);
  String get _value =>
      '#${_hsv.toColor().toARGB32().toRadixString(16).substring(2)}';
  void _update(HSVColor value) => setState(() {
    _hsv = value;
    _hex.text = _value;
  });
  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text('Custom color'),
        const SizedBox(height: 16),
        SizedBox(
          width: 220,
          height: 220,
          child: LayoutBuilder(
            builder: (context, constraints) => GestureDetector(
              onPanDown: (d) => _point(d.localPosition),
              onPanUpdate: (d) => _point(d.localPosition),
              child: CustomPaint(painter: _ColorWheel(_hsv)),
            ),
          ),
        ),
        Slider(
          value: _hsv.value,
          onChanged: (v) => _update(_hsv.withValue(v)),
          semanticFormatterCallback: (v) =>
              '${(v * 100).round()} percent brightness',
        ),
        TextField(
          controller: _hex,
          decoration: const InputDecoration(labelText: 'Hex'),
          onChanged: (v) {
            if (RegExp(r'^#[a-fA-F0-9]{6}$').hasMatch(v)) {
              setState(() => _hsv = HSVColor.fromColor(_hexColor(v)));
            }
          },
        ),
        const SizedBox(height: 16),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(_value),
              child: const Text('Save'),
            ),
          ],
        ),
      ],
    ),
  );
  void _point(Offset point) {
    final p = point - const Offset(110, 110);
    final angle = (math.atan2(p.dy, p.dx) * 180 / math.pi + 360) % 360;
    _update(_hsv.withHue(angle).withSaturation((p.distance / 110).clamp(0, 1)));
  }
}

class _ColorWheel extends CustomPainter {
  const _ColorWheel(this.color);
  final HSVColor color;
  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero), radius = size.width / 2;
    final rect = Offset.zero & size;
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = const SweepGradient(
          colors: [
            Colors.red,
            Colors.yellow,
            Colors.green,
            Colors.cyan,
            Colors.blue,
            Colors.purple,
            Colors.red,
          ],
        ).createShader(rect),
    );
    canvas.drawCircle(
      center,
      radius,
      Paint()
        ..shader = RadialGradient(
          colors: [Colors.white, Colors.white.withValues(alpha: 0)],
        ).createShader(rect),
    );
    final position =
        center +
        Offset(
              math.cos(color.hue * math.pi / 180),
              math.sin(color.hue * math.pi / 180),
            ) *
            color.saturation *
            radius;
    canvas.drawCircle(
      position,
      7,
      Paint()
        ..color = Colors.black
        ..style = PaintingStyle.stroke
        ..strokeWidth = 3,
    );
    canvas.drawCircle(
      position,
      7,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_ColorWheel oldDelegate) => color != oldDelegate.color;
}
