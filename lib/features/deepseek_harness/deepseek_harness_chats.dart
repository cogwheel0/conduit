import 'dart:async';

import 'package:conduit_core/features/deepseek_harness/deepseek_harness.dart';
import 'package:conduit_core/features/deepseek_harness/deepseek_harness_client.dart';
import 'package:flutter/services.dart' show TextCapitalization;
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../l10n/app_localizations.dart';
import '../../shared/theme/theme_extensions.dart';
import '../../shared/utils/external_link_launcher.dart';
import '../../shared/widgets/adaptive_route_shell.dart';
import '../../shared/widgets/adaptive_selection_sheet.dart';
import '../../shared/widgets/adaptive_toolbar_components.dart';
import '../../shared/widgets/markdown/renderer/block_renderer.dart'
    show MarkdownHeavyBlockPolicy;
import '../../shared/widgets/markdown/renderer/conduit_markdown_widget.dart';
import '../../shared/widgets/platform_ui/platform_ui.dart';
import '../../shared/widgets/platform_ui/vocabulary.dart';

final harnessClientFactoryProvider =
    Provider<DeepSeekHarnessClient Function(DeepSeekHarnessConnection)>(
      (ref) => DeepSeekHarnessClient.new,
    );

// Drafts belong to one saved sign-in and session. Replacing or forgetting
// that sign-in releases its drafts, including when its server address is reused.
final _draftsBySignIn = Expando<Map<String, _SessionDraft>>();

String _connectionError(AppLocalizations l10n, Object? error) =>
    switch (error is DeepSeekHarnessException ? error.reason : null) {
      DeepSeekHarnessFailure.unauthorized => l10n.deepSeekHarnessUnauthorized,
      DeepSeekHarnessFailure.untrustedHost => l10n.deepSeekHarnessUntrustedHost,
      _ => l10n.deepSeekHarnessUnavailable,
    };

Future<T?> _choose<T>(
  BuildContext context,
  String title,
  List<T> items, {
  required String Function(T) label,
  String? Function(T)? subtitle,
  bool Function(T)? selected,
}) => showAdaptiveSelectionSheet<T>(
  context: context,
  builder: (context) => AdaptiveSelectionSheet(
    title: title,
    itemCount: items.length,
    itemBuilder: (context, index) {
      final item = items[index];
      return AdaptiveSelectionTile(
        title: label(item),
        subtitle: subtitle?.call(item),
        selected: selected?.call(item) ?? false,
        onTap: () => Navigator.of(context).pop(item),
      );
    },
  ),
);

class DeepSeekHarnessChats extends ConsumerStatefulWidget {
  const DeepSeekHarnessChats({
    super.key,
    required this.connection,
    required this.onOpenWorkspace,
    required this.onEditConnection,
    required this.onExit,
    required this.onReady,
  });

  final DeepSeekHarnessConnection connection;
  final Future<void> Function(String? sessionTitle) onOpenWorkspace;
  final VoidCallback onEditConnection;
  final VoidCallback onExit;
  final VoidCallback onReady;

  @override
  ConsumerState<DeepSeekHarnessChats> createState() => _ChatsState();
}

class _ChatsState extends ConsumerState<DeepSeekHarnessChats> {
  late DeepSeekHarnessClient _client;
  late Future<(List<HarnessSession>, List<HarnessWorkspace>)> _catalog;
  String? _selectedId;
  HarnessSession? _summary;
  String? _workspaceId;
  bool _exiting = false;
  bool _creating = false;
  bool _showingWorkspace = false;
  bool _ready = false;
  Object? _actionError;

  @override
  void initState() {
    super.initState();
    _initClient();
  }

  @override
  void didUpdateWidget(DeepSeekHarnessChats oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.connection != widget.connection) {
      _client.close();
      _initClient();
    }
  }

  void _initClient() {
    _client = ref.read(harnessClientFactoryProvider)(widget.connection);
    _selectedId = _workspaceId = null;
    _summary = null;
    _actionError = null;
    _ready = _creating = _showingWorkspace = false;
    _catalog = _load(_client);
  }

  Future<(List<HarnessSession>, List<HarnessWorkspace>)> _load(
    DeepSeekHarnessClient client,
  ) async {
    final sessions = await client.listSessions();
    final workspaces = await client.listWorkspaces();
    if (mounted && identical(_client, client) && !_ready && !_exiting) {
      _ready = true;
      widget.onReady();
    }
    return (sessions, workspaces);
  }

  void _refresh() => setState(() {
    _actionError = null;
    _catalog = _load(_client);
  });

  void _back() {
    if (_selectedId == null) {
      _exiting = true;
      widget.onExit();
      return;
    }
    setState(() {
      _selectedId = null;
      _summary = null;
      _actionError = null;
      _catalog = _load(_client);
    });
  }

  Future<void> _workspace({String? id, String? title}) async {
    if (_showingWorkspace) return;
    _showingWorkspace = true;
    try {
      if (id != null) {
        title ??= _summary?.title ?? '';
        if (title.isEmpty) {
          // Harness can assign a title after the first turn in a new session.
          try {
            final sessions = await _client.listSessions();
            final latest = sessions
                .where((session) => session.id == id)
                .firstOrNull;
            if (!mounted || _selectedId != id) return;
            if (latest != null) {
              title = latest.title;
              setState(() => _summary = latest);
            }
          } on DeepSeekHarnessException {
            // The workspace can still open with its general session picker.
          }
        }
      }
      if (mounted && !_exiting) await widget.onOpenWorkspace(title);
    } finally {
      _showingWorkspace = false;
      if (mounted && id == null) _refresh();
    }
  }

  Future<void> _newChat(List<HarnessWorkspace> workspaces) async {
    if (_creating || workspaces.isEmpty) return;
    final client = _client;
    try {
      final selected = workspaces
          .where((item) => item.id == _workspaceId)
          .firstOrNull;
      final workspace =
          selected ??
          (workspaces.length == 1
              ? workspaces.single
              : await _choose(
                  context,
                  AppLocalizations.of(context)!.workspaceTitle,
                  workspaces,
                  label: (w) => w.name,
                ));
      if (!mounted ||
          client != _client ||
          workspace == null ||
          _creating ||
          _exiting) {
        return;
      }
      setState(() {
        _creating = true;
        _actionError = null;
      });
      final id = await client.createSession(workspaceId: workspace.id);
      if (mounted && client == _client && _selectedId == null && !_exiting) {
        setState(() {
          _selectedId = id;
          _summary = null;
        });
      }
    } catch (e) {
      if (mounted && client == _client) setState(() => _actionError = e);
    } finally {
      if (mounted && client == _client) setState(() => _creating = false);
    }
  }

  @override
  void dispose() {
    _client.close();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final session = _selectedId;
    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (popped, _) {
        if (!popped) _back();
      },
      child: session != null
          ? _SessionChat(
              key: ValueKey((widget.connection, session)),
              client: _client,
              sessionId: session,
              summary: _summary,
              drafts: _draftsBySignIn[widget.connection] ??= {},
              onBack: _back,
              onWorkspace: (title) => _workspace(id: session, title: title),
            )
          : FutureBuilder(
              key: ObjectKey(widget.connection),
              future: _catalog,
              builder: (context, snapshot) {
                final sessions = snapshot.data?.$1 ?? const <HarnessSession>[];
                final workspaces =
                    snapshot.data?.$2 ?? const <HarnessWorkspace>[];
                final selected = workspaces
                    .where((item) => item.id == _workspaceId)
                    .firstOrNull;
                final visible = selected == null
                    ? sessions
                    : sessions
                          .where((s) => selected.sessionIds.contains(s.id))
                          .toList();
                final error = snapshot.error ?? _actionError;
                return AdaptiveRouteShell(
                  bodySafeArea: true,
                  safeAreaTop: false,
                  appBar: AdaptiveAppBar(
                    title: l10n.deepSeekHarnessTitle,
                    leading: ConduitAdaptiveAppBarIconButton(
                      icon: Icons.arrow_back,
                      iosSymbol: 'chevron.backward',
                      semanticLabel: l10n.deepSeekHarnessBack,
                      onPressed: _back,
                    ),
                    actions: [
                      AdaptiveAppBarAction(
                        icon: Icons.open_in_browser,
                        iosSymbol: 'safari',
                        semanticLabel: l10n.deepSeekHarnessOpenWorkspace,
                        onPressed: _workspace,
                      ),
                      AdaptiveAppBarAction(
                        icon: Icons.settings_outlined,
                        iosSymbol: 'gearshape',
                        semanticLabel: l10n.edit,
                        onPressed: widget.onEditConnection,
                      ),
                      AdaptiveAppBarAction(
                        icon: Icons.edit_square,
                        iosSymbol: 'square.and.pencil',
                        semanticLabel: l10n.newChat,
                        onPressed: workspaces.isEmpty || _creating
                            ? null
                            : () => _newChat(workspaces),
                      ),
                    ],
                  ),
                  body: Column(
                    children: [
                      if (snapshot.connectionState == ConnectionState.waiting ||
                          _creating)
                        const AdaptiveProgressIndicator.linear(),
                      if (error != null)
                        _ErrorRow(
                          text: _connectionError(l10n, error),
                          retry: _refresh,
                        ),
                      if (workspaces.length > 1 || selected != null)
                        AdaptiveListTile(
                          leading: const Icon(Icons.folder_outlined),
                          title: Text(
                            selected?.name ?? l10n.workspaceKnowledgeViewAll,
                          ),
                          subtitle: Text(l10n.workspaceTitle),
                          trailing: const Icon(Icons.expand_more),
                          onTap: () async {
                            final choices = [
                              '',
                              ...workspaces.map((w) => w.id),
                            ];
                            final result = await _choose(
                              context,
                              l10n.workspaceTitle,
                              choices,
                              label: (id) =>
                                  workspaces
                                      .where((w) => w.id == id)
                                      .firstOrNull
                                      ?.name ??
                                  l10n.workspaceKnowledgeViewAll,
                              selected: (id) => id == (selected?.id ?? ''),
                            );
                            if (mounted && result != null) {
                              setState(
                                () => _workspaceId = result.isEmpty
                                    ? null
                                    : result,
                              );
                            }
                          },
                        ),
                      if (snapshot.hasData)
                        Expanded(
                          child: visible.isEmpty
                              ? Center(
                                  child: Padding(
                                    padding: const EdgeInsets.all(Spacing.lg),
                                    child: Column(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Text(
                                          workspaces.isEmpty
                                              ? l10n.deepSeekHarnessNoWorkspaces
                                              : l10n.noConversationsYet,
                                          textAlign: TextAlign.center,
                                        ),
                                        const SizedBox(height: Spacing.md),
                                        AdaptiveButton(
                                          label: workspaces.isEmpty
                                              ? l10n.deepSeekHarnessOpenWorkspace
                                              : l10n.newChat,
                                          onPressed: workspaces.isEmpty
                                              ? _workspace
                                              : _creating
                                              ? null
                                              : () => _newChat(workspaces),
                                        ),
                                      ],
                                    ),
                                  ),
                                )
                              : ListView.builder(
                                  itemCount: visible.length,
                                  itemBuilder: (_, index) {
                                    final row = visible[index];
                                    return AdaptiveListTile(
                                      key: ValueKey(row.id),
                                      leading: const Icon(
                                        Icons.chat_bubble_outline,
                                      ),
                                      title: Text(
                                        row.title.isEmpty
                                            ? l10n.newChat
                                            : row.title,
                                        maxLines: 2,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                      subtitle: row.needsWorkspace
                                          ? Text(
                                              l10n.deepSeekHarnessOpenWorkspace,
                                            )
                                          : row.running
                                          ? Text(l10n.scheduledTaskRunning)
                                          : null,
                                      trailing: const Icon(Icons.chevron_right),
                                      onTap: row.needsWorkspace
                                          ? () => _workspace(title: row.title)
                                          : () => setState(() {
                                              _selectedId = row.id;
                                              _summary = row;
                                            }),
                                    );
                                  },
                                ),
                        ),
                      if (snapshot.hasData)
                        AdaptiveButton(
                          label: l10n.terminalPortPreviewReload,
                          style: AdaptiveButtonStyle.plain,
                          onPressed: _refresh,
                        ),
                    ],
                  ),
                );
              },
            ),
    );
  }
}

class _ErrorRow extends StatelessWidget {
  const _ErrorRow({required this.text, this.retry});
  final String text;
  final VoidCallback? retry;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(
      horizontal: Spacing.md,
      vertical: Spacing.xs,
    ),
    child: Row(
      children: [
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: Theme.of(context).colorScheme.error),
          ),
        ),
        if (retry != null)
          AdaptiveButton(
            label: AppLocalizations.of(context)!.retry,
            style: AdaptiveButtonStyle.plain,
            onPressed: retry,
          ),
      ],
    ),
  );
}

class _SessionDraft extends TextEditingController {
  bool sending = false;
  String? _requestId;

  String beginRequest() => _requestId ??= const Uuid().v4();

  void acknowledge(String requestId) {
    if (_requestId == requestId) clear();
  }

  @override
  set value(TextEditingValue next) {
    // Cursor movement preserves an unconfirmed prompt. Editing starts a new one.
    if (next.text != text) _requestId = null;
    super.value = next;
  }

  void setSending(bool value) {
    sending = value;
    notifyListeners();
  }
}

class _SessionChat extends StatefulWidget {
  const _SessionChat({
    super.key,
    required this.client,
    required this.sessionId,
    required this.summary,
    required this.drafts,
    required this.onBack,
    required this.onWorkspace,
  });
  final DeepSeekHarnessClient client;
  final String sessionId;
  final HarnessSession? summary;
  final Map<String, _SessionDraft> drafts;
  final VoidCallback onBack;
  final Future<void> Function(String? title) onWorkspace;

  @override
  State<_SessionChat> createState() => _SessionChatState();
}

class _SessionChatState extends State<_SessionChat>
    with WidgetsBindingObserver {
  late final _draft = widget.drafts.putIfAbsent(
    widget.sessionId,
    _SessionDraft.new,
  );
  final _scroll = ScrollController(keepScrollOffset: false);
  bool _loadingEarlier = false;
  StreamSubscription<HarnessTranscript>? _subscription;
  HarnessTranscript? _view;
  Object? _streamError;
  String? _actionError;
  bool _busy = false;
  bool _awaitingSnapshot = true;
  bool _inWorkspace = false;
  bool _foreground = true;
  int _generation = 0;
  int _limit = 100;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _follow();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.inactive:
        break;
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
      case AppLifecycleState.detached:
        if (_foreground) {
          _foreground = false;
          _detach();
        }
      case AppLifecycleState.resumed:
        if (!_foreground) {
          _foreground = true;
          _follow();
        }
    }
  }

  void _detach() {
    _generation++;
    unawaited(_subscription?.cancel());
    _subscription = null;
  }

  void _follow() {
    if (!_foreground || _inWorkspace) return;
    _detach();
    final generation = _generation;
    setState(() {
      _awaitingSnapshot = true;
      _streamError = null;
    });
    _subscription = widget.client
        .follow(widget.sessionId, maxMessages: _limit)
        .listen(
          (next) {
            if (!mounted || generation != _generation) return;
            final scroll = _scroll.hasClients ? _scroll.position : null;
            final atEnd = scroll == null || scroll.extentAfter < 48;
            final oldExtent = scroll?.maxScrollExtent ?? 0;
            final oldOffset = scroll?.pixels ?? 0;
            final prepend = _loadingEarlier;
            _loadingEarlier = false;
            setState(() {
              _view = next;
              _awaitingSnapshot = false;
            });
            if (atEnd || prepend) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (!mounted ||
                    generation != _generation ||
                    !_scroll.hasClients) {
                  return;
                }
                final position = _scroll.position;
                if ((position.pixels - oldOffset).abs() > 1) return;
                final target = prepend
                    ? oldOffset + (position.maxScrollExtent - oldExtent)
                    : position.maxScrollExtent;
                _scroll.jumpTo(
                  target
                      .clamp(position.minScrollExtent, position.maxScrollExtent)
                      .toDouble(),
                );
              });
            }
          },
          onError: (Object e) {
            if (mounted && generation == _generation) {
              setState(() {
                _streamError = e;
                _awaitingSnapshot = false;
              });
            }
          },
          onDone: () {
            if (mounted && generation == _generation) {
              setState(() {
                _streamError ??= const DeepSeekHarnessException(
                  DeepSeekHarnessFailure.unavailable,
                );
                _awaitingSnapshot = false;
              });
            }
          },
        );
  }

  Future<void> _workspace() async {
    if (_inWorkspace) return;
    _inWorkspace = true;
    _detach();
    try {
      await widget.onWorkspace(_view?.title);
    } finally {
      _inWorkspace = false;
      if (mounted) _follow();
    }
  }

  Future<void> _send() async {
    final draft = _draft.text;
    final current = _currentSnapshot;
    if (_busy ||
        _draft.sending ||
        draft.trim().isEmpty ||
        current == null ||
        current.running ||
        current.hasPendingRequest) {
      return;
    }
    _draft.setSending(true);
    final requestId = _draft.beginRequest();
    setState(() => _actionError = null);
    try {
      await widget.client.send(
        widget.sessionId,
        draft.trim(),
        requestId: requestId,
      );
      _draft.acknowledge(requestId);
    } catch (_) {
      if (mounted) {
        setState(
          () =>
              _actionError = AppLocalizations.of(context)!
                  .deepSeekHarnessSendUnconfirmed,
        );
      }
    } finally {
      _draft.setSending(false);
    }
  }

  HarnessTranscript? get _currentSnapshot =>
      _subscription != null && !_awaitingSnapshot && _streamError == null
      ? _view
      : null;

  Future<void> _stop(HarnessTranscript observed) async {
    if (_busy || _currentSnapshot != observed || !observed.running) return;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      await widget.client.interrupt(widget.sessionId);
    } catch (e) {
      if (mounted) {
        setState(
          () =>
              _actionError = _connectionError(AppLocalizations.of(context)!, e),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _model() async {
    if (_busy) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _actionError = null;
    });
    try {
      final models = await widget.client.listModels();
      if (!mounted) return;
      if (models.isEmpty) {
        setState(() => _actionError = l10n.noModelsAvailable);
        return;
      }
      final id = _view?.modelId ?? widget.summary?.modelId;
      final provider = _view?.modelProvider ?? widget.summary?.modelProvider;
      final model = await _choose(
        context,
        l10n.scheduledTaskModelChoose,
        models,
        label: (m) => m.name.isEmpty ? m.id : m.name,
        subtitle: (m) => m.provider,
        selected: (m) => m.id == id && m.provider == provider,
      );
      if (mounted && model != null) {
        await widget.client.selectModel(widget.sessionId, model);
        if (mounted) _follow();
      }
    } catch (e) {
      if (mounted) setState(() => _actionError = _connectionError(l10n, e));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _detach();
    _scroll.dispose();
    if (_draft.text.isEmpty && !_draft.sending) {
      widget.drafts.remove(widget.sessionId);
      _draft.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final view = _view;
    final running = view?.running ?? widget.summary?.running ?? false;
    final needsWorkspace =
        view?.needsWorkspace ?? widget.summary?.needsWorkspace ?? false;
    final title = view?.title ?? widget.summary?.title ?? '';
    final messages = view?.messages ?? const <HarnessMessage>[];
    final current = _currentSnapshot;
    final canAct = !_busy && current != null;
    final canSend = canAct && !running && !(view?.hasPendingRequest ?? false);
    return AdaptiveRouteShell(
      bodySafeArea: true,
      safeAreaTop: false,
      appBar: AdaptiveAppBar(
        title: title.isEmpty ? l10n.newChat : title,
        leading: ConduitAdaptiveAppBarIconButton(
          icon: Icons.arrow_back,
          iosSymbol: 'chevron.backward',
          semanticLabel: l10n.sidebarChatsTab,
          onPressed: widget.onBack,
        ),
        actions: [
          AdaptiveAppBarAction(
            icon: Icons.open_in_browser,
            iosSymbol: 'safari',
            semanticLabel: l10n.deepSeekHarnessOpenWorkspace,
            onPressed: _workspace,
          ),
        ],
      ),
      body: Column(
        children: [
          if (_awaitingSnapshot) const AdaptiveProgressIndicator.linear(),
          if (_streamError != null)
            _ErrorRow(
              text: _connectionError(l10n, _streamError),
              retry: _follow,
            ),
          if (_actionError != null) _ErrorRow(text: _actionError!),
          Expanded(
            child: ListView.builder(
              key: PageStorageKey(widget.sessionId),
              controller: _scroll,
              padding: const EdgeInsets.symmetric(
                horizontal: Spacing.pagePadding,
                vertical: Spacing.sm,
              ),
              itemCount: messages.length + (view?.hasMore == true ? 1 : 0),
              itemBuilder: (_, index) {
                final hasEarlier = view?.hasMore == true;
                if (hasEarlier && index == 0) {
                  return AdaptiveButton(
                    label: l10n.workspaceLoadMore,
                    style: AdaptiveButtonStyle.plain,
                    onPressed: _awaitingSnapshot
                        ? null
                        : () {
                            _loadingEarlier = true;
                            _limit += 100;
                            _follow();
                          },
                  );
                }
                return _Message(
                  message: messages[index - (hasEarlier ? 1 : 0)],
                );
              },
            ),
          ),
          if (view?.lastTurnFailed == true)
            _ErrorRow(text: l10n.pushReplyFailedBody),
          if (needsWorkspace || view?.lastTurnFailed == true)
            AdaptiveButton(
              label: view?.hasPendingRequest == true
                  ? l10n.deepSeekHarnessReviewRequest
                  : l10n.deepSeekHarnessOpenWorkspace,
              onPressed: _workspace,
            ),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: Spacing.md,
              vertical: Spacing.xs,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                AdaptiveButton(
                  label:
                      view?.modelId ??
                      widget.summary?.modelId ??
                      l10n.scheduledTaskModelChoose,
                  semanticLabel: l10n.scheduledTaskModelChoose,
                  style: AdaptiveButtonStyle.plain,
                  size: AdaptiveButtonSize.small,
                  onPressed: !canAct || running ? null : _model,
                ),
                Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: [
                    Expanded(
                      child: AdaptiveTextField(
                        key: const ValueKey('harness-message-field'),
                        controller: _draft,
                        placeholder: l10n.channelMessageHint,
                        minLines: 1,
                        maxLines: 5,
                        textCapitalization: TextCapitalization.sentences,
                      ),
                    ),
                    const SizedBox(width: Spacing.sm),
                    ValueListenableBuilder(
                      valueListenable: _draft,
                      builder: (_, value, _) => AdaptiveButton.icon(
                        icon: running ? Icons.stop_rounded : Icons.arrow_upward,
                        semanticLabel: running
                            ? l10n.stopGenerating
                            : l10n.send,
                        onPressed: running
                            ? (canAct ? () => _stop(current) : null)
                            : (canSend &&
                                      !_draft.sending &&
                                      value.text.trim().isNotEmpty
                                  ? _send
                                  : null),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({required this.message});
  final HarnessMessage message;

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme;
    final user = message.role == 'user';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: Spacing.sm),
      child: user
          ? Align(
              alignment: AlignmentDirectional.centerEnd,
              child: FractionallySizedBox(
                widthFactor: .88,
                alignment: AlignmentDirectional.centerEnd,
                child: Align(
                  alignment: AlignmentDirectional.centerEnd,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: theme.chatBubbleUser,
                      borderRadius: BorderRadius.circular(
                        AppBorderRadius.chatBubble,
                      ),
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: Spacing.md,
                        vertical: Spacing.sm,
                      ),
                      child: Text(message.text),
                    ),
                  ),
                ),
              ),
            )
          : ConduitMarkdownWidget(
              data: message.text,
              enableStreamingTextFade: message.streaming,
              heavyBlockPolicy: MarkdownHeavyBlockPolicy.defer,
              onLinkTap: (url, _) => launchExternalLink(url, scope: 'harness'),
              // Harness attachment routes belong to its workspace. Avoid
              // loading remote images automatically while reading a chat.
              imageBuilder: (_, alt, _) => Text(alt ?? ''),
            ),
    );
  }
}
