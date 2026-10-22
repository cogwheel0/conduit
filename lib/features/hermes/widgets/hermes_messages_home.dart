import 'hermes_conversation_stage.dart';

import 'dart:math' as math;

import '../../../platform/motion_probe.dart';

import 'package:conduit_core/services/settings_service.dart';

import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:markdown/markdown.dart' as markdown;
import 'package:conduit_core/features/hermes/models/hermes_bot.dart';
import 'package:conduit_core/features/hermes/models/hermes_bot_group.dart';
import 'package:conduit_core/features/hermes/models/hermes_session.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/ui_utils.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../providers/hermes_messages.dart';
import '../providers/hermes_mobile_navigation.dart';
import 'hermes_mobile_shell.dart'
    show
        HermesLoadError,
        groupHermesConversations,
        HermesConversationPeriod,
        startHermesMobileConversation;
import 'hermes_session_tile.dart';
import 'hermes_bot_avatar.dart';
import 'hermes_message_icon.dart';
import 'hermes_file_preview.dart';
import '../views/hermes_bot_setup_page.dart';
import '../views/hermes_group_setup_page.dart';
import '../views/hermes_group_chat_page.dart';
import '../views/hermes_routine_detail_page.dart';
import '../providers/hermes_workspace.dart';
import 'hermes_conversation_actions.dart';
import 'hermes_mobile_shell.dart' show HermesProfileButton;

import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';

/// Keeps list previews readable and avoids repeating the conversation title.
String? hermesMessagePreview(String title, String? preview) {
  String nodeText(markdown.Node node) => node is markdown.Element
      ? (node.children ?? const <markdown.Node>[])
            .map(nodeText)
            .join(
              const {
                    'ul',
                    'ol',
                    'blockquote',
                    'table',
                    'thead',
                    'tbody',
                    'tr',
                  }.contains(node.tag)
                  ? ' '
                  : '',
            )
      : node.textContent;
  String plain(String text) =>
      markdown.Document(
            extensionSet: markdown.ExtensionSet.gitHubFlavored,
            encodeHtml: false,
          )
          .parseLines(text.split('\n'))
          .map(nodeText)
          .join(' ')
          .replaceAll(RegExp(r'\s+'), ' ')
          .trim();

  final text = plain(preview ?? '');
  final normalizedText = text.toLowerCase();
  final normalizedTitle = plain(title).toLowerCase();
  final truncation = RegExp(r'(?:\.{3}|…)$').firstMatch(normalizedTitle);
  final prefix = truncation == null
      ? ''
      : normalizedTitle.substring(0, truncation.start).trimRight();
  // Auto-generated titles retain a long prompt prefix. Short titles can use
  // an ellipsis intentionally, so their distinct replies remain visible.
  final repeatsTruncatedTitle =
      prefix.length >= 20 &&
      (normalizedText.startsWith(prefix) || prefix.startsWith(normalizedText));
  if (truncation == null &&
      normalizedTitle.length >= 32 &&
      normalizedText.startsWith(normalizedTitle)) {
    final remainder = text.substring(plain(title).length);
    if (remainder.isEmpty || !RegExp(r'^[\s:—–,.-]').hasMatch(remainder)) {
      return null;
    }
    final distinct = remainder.replaceFirst(RegExp(r'^[\s:—–,.-]+'), '').trim();
    return distinct.isEmpty ? null : distinct;
  }

  return text.isEmpty ||
          normalizedText == normalizedTitle ||
          repeatsTruncatedTitle
      ? null
      : text;
}

final hermesMessageAvatarProvider = FutureProvider.autoDispose
    .family<String?, String>(
      (ref, profile) async =>
          ref.watch(hermesMessagesBackendProvider)?.botAvatar(profile),
    );

String hermesMessageTimestamp(
  DateTime? date,
  DateTime now,
  String locale, {
  String yesterday = 'Yesterday',
}) {
  if (date == null) return '';
  final local = date.toLocal(), current = now.toLocal();
  final age = current.difference(local);
  if (!age.isNegative && age < const Duration(hours: 12)) {
    return DateFormat.jm(locale).format(local);
  }
  final previous = DateTime(current.year, current.month, current.day - 1);
  if (local.year == previous.year &&
      local.month == previous.month &&
      local.day == previous.day) {
    return yesterday;
  }
  return DateFormat.MMMd(locale).format(local);
}

Future<void> openHermesBotConversation(
  BuildContext context,
  WidgetRef ref,
  HermesBotConversation row,
) async {
  final backend = ref.read(hermesMessagesBackendProvider),
      service = ref.read(hermesApiServiceProvider);
  if (backend == null) return;
  try {
    final id = row.session?.id ?? await backend.openBotChat(row.bot);
    if (!context.mounted ||
        !identical(backend, ref.read(hermesMessagesBackendProvider)) ||
        !identical(service, ref.read(hermesApiServiceProvider))) {
      return;
    }
    backend.bindBotSession(row.bot.name, id);
    String? avatar;
    if (row.bot.hasAvatar) {
      try {
        avatar = await ref.read(
          hermesMessageAvatarProvider(row.bot.name).future,
        );
      } catch (_) {
        /* The shape avatar remains usable. */
      }
    }
    if (!context.mounted ||
        !identical(service, ref.read(hermesApiServiceProvider))) {
      return;
    }
    await openHermesSession(
      context,
      ref,
      HermesSessionSummary(
        id: id,
        title: row.bot.title,
        updatedAt: row.lastActive,
      ),
      bot: row.bot,
      botAvatar: avatar,
    );
    if (context.mounted &&
        ref.read(activeConversationProvider)?.metadata['hermesSessionId'] ==
            id) {
      unawaited(
        ref
            .read(hermesMessageReadReceiptsProvider.notifier)
            .seen('bot:${row.bot.name}'),
      );
    }
  } catch (_) {
    if (context.mounted) {
      UiUtils.showMessage(
        context,
        AppLocalizations.of(context)!.messagesLoadFailed,
        isError: true,
      );
    }
  }
}

class HermesMessagesHome extends ConsumerStatefulWidget {
  const HermesMessagesHome({super.key});
  @override
  ConsumerState<HermesMessagesHome> createState() => _HermesMessagesHomeState();
}

class _HermesMessagesHomeState extends ConsumerState<HermesMessagesHome>
    with SingleTickerProviderStateMixin {
  final _chatMenuKeys = <String, GlobalKey<PopupMenuButtonState<String>>>{};
  GlobalKey<PopupMenuButtonState<String>> _chatMenuKey(String id) =>
      _chatMenuKeys.putIfAbsent(
        id,
        () => GlobalKey<PopupMenuButtonState<String>>(),
      );
  final _search = TextEditingController();
  late final AnimationController _mode = AnimationController(
    vsync: this,
    duration: AnimationDuration.searchMode,
    reverseDuration: AnimationDuration.searchModeReverse,
  );
  int _searchEpoch = 0;
  bool _searchActive = false;
  bool _showArchived = false;
  bool _reduceMotion = false;
  ModalRoute<dynamic>? _categoryRoute;
  final _categoryAnchor = GlobalKey();

  final _focus = FocusNode();
  final _chatScroll = ScrollController();
  final _botScroll = ScrollController();
  double _savedListOffset = 0;
  HermesMessagesTab _ownedTab = HermesMessagesTab.chats;
  @override
  void initState() {
    super.initState();
    ref.listenManual(hermesMessagesNavigationProvider, (_, next) {
      final work = ref.read(hermesMobileNavigationProvider);
      _syncSearch(
        next.search && work.area == HermesWorkArea.chat && !work.conversation,
      );
    });
    ref.listenManual(hermesMobileNavigationProvider, (_, next) {
      _syncSearch(
        ref.read(hermesMessagesNavigationProvider).search &&
            next.area == HermesWorkArea.chat &&
            !next.conversation,
      );
    });
  }

  Timer? _debounce;
  String _query = '';
  HermesSearchCategory _category = HermesSearchCategory.all;
  Object? _service;
  @override
  void dispose() {
    _debounce?.cancel();
    _mode.dispose();
    _chatScroll.dispose();
    _botScroll.dispose();
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _startSearch() {
    _search.clear();
    _query = '';
    _category = HermesSearchCategory.all;
    ref.read(hermesMessagesNavigationProvider.notifier).search();
  }

  void _closeSearch() {
    ref.read(hermesMessagesNavigationProvider.notifier).closeSearch();
  }

  void _syncSearch(bool active) {
    if (active == _searchActive) return;
    _searchActive = active;
    final epoch = ++_searchEpoch;
    _debounce?.cancel();
    _focus.unfocus();
    if (_categoryRoute?.isCurrent == true) _categoryRoute!.navigator?.pop();
    _categoryRoute = null;
    if (active) {
      _ownedTab = ref.read(hermesMessagesNavigationProvider).tab;
      final scroll = _ownedTab == HermesMessagesTab.chats
          ? _chatScroll
          : _botScroll;
      _savedListOffset = scroll.hasClients ? scroll.offset : 0;
      MotionProbe.mark('search-opening');
      if (_reduceMotion) {
        _mode.value = 1;
        _focusWhenReady(epoch);
      } else {
        _mode.forward().whenCompleteOrCancel(() => _focusWhenReady(epoch));
      }
    } else {
      MotionProbe.mark('search-closing');
      // Removing the live results owner releases the autoDispose stream and
      // its cancellation token. No result listener survives logical exit.
      if (_reduceMotion) {
        _mode.value = 0;
        _restoreList(epoch);
      } else {
        _mode.reverse().whenCompleteOrCancel(() => _restoreList(epoch));
      }
    }
  }

  void _restoreList(int epoch) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted ||
          epoch != _searchEpoch ||
          _searchActive ||
          !_mode.isDismissed) {
        return;
      }
      final scroll = _ownedTab == HermesMessagesTab.chats
          ? _chatScroll
          : _botScroll;
      if (scroll.hasClients) {
        scroll.jumpTo(
          _savedListOffset.clamp(
            scroll.position.minScrollExtent,
            scroll.position.maxScrollExtent,
          ),
        );
      }
      MotionProbe.mark('search-closed');
    });
  }

  void _focusWhenReady(int epoch) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted &&
          epoch == _searchEpoch &&
          _searchActive &&
          _mode.isCompleted &&
          ref.read(hermesMessagesNavigationProvider).search) {
        _focus.requestFocus();
        MotionProbe.mark('search-open');
      }
    });
  }

  void _changeQuery(String value) {
    _debounce?.cancel();
    final epoch = _searchEpoch;
    _debounce = Timer(const Duration(milliseconds: 300), () {
      if (mounted && _searchActive && epoch == _searchEpoch) {
        setState(() => _query = value.trim());
      }
    });
  }

  Future<void> _categories(HermesMessagesTab tab) async {
    if (!_searchActive || !_mode.isCompleted) return;
    final epoch = _searchEpoch;
    final box =
        _categoryAnchor.currentContext!.findRenderObject()! as RenderBox;
    final overlay =
        Overlay.of(context).context.findRenderObject()! as RenderBox;
    final rect = box.localToGlobal(Offset.zero, ancestor: overlay) & box.size;
    final choice = await showMenu<HermesSearchCategory>(
      context: context,
      position: RelativeRect.fromRect(rect, Offset.zero & overlay.size),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      items: [
        for (final category in hermesSearchCategories(tab))
          PopupMenuItem(
            key: ValueKey('messages-search-category-${category.name}'),
            value: category,
            child: Builder(
              builder: (menuContext) {
                _categoryRoute = ModalRoute.of(menuContext);
                return Semantics(
                  key: ValueKey(
                    'messages-search-category-state-${category.name}',
                  ),
                  selected: category == _category,
                  child: Row(
                    children: [
                      Icon(_categoryIcon(category), size: 18),
                      const SizedBox(width: 8),
                      Expanded(child: Text(_categoryLabel(category))),
                      if (category == _category) ...[
                        const SizedBox(width: 8),
                        Icon(
                          HermesMessageIcons.check,
                          key: const ValueKey(
                            'messages-search-category-selected',
                          ),
                          size: 18,
                          color: context.conduitTheme.textPrimary,
                        ),
                      ],
                    ],
                  ),
                );
              },
            ),
          ),
      ],
    );
    if (!mounted || epoch != _searchEpoch || !_searchActive) return;
    _categoryRoute = null;
    if (choice != null) setState(() => _category = choice);
  }

  Future<void> _create(String kind) async {
    if (kind == 'bot') {
      final bot = await Navigator.of(context).push<HermesBot>(
        MaterialPageRoute(builder: (_) => const HermesBotSetupPage()),
      );
      if (bot != null && mounted) {
        ref.invalidate(hermesBotsProvider);
        ref.invalidate(hermesMessagesBotsProvider);
        ref.invalidate(hermesBotConversationsProvider);
        await openHermesBotConversation(
          context,
          ref,
          HermesBotConversation(bot: bot),
        );
      }
    } else {
      final group = await Navigator.of(context).push<HermesBotGroup>(
        MaterialPageRoute(builder: (_) => const HermesGroupSetupPage()),
      );
      if (group != null && mounted) _openGroup(group);
    }
  }

  Future<void> _openGroup(HermesBotGroup group) async {
    final service = ref.read(hermesApiServiceProvider);
    _focus.unfocus();
    try {
      final archive = await ref.read(hermesGroupArchiveProvider.future);
      final full = await archive.read(group);
      if (!mounted || !identical(service, ref.read(hermesApiServiceProvider))) {
        return;
      }
      await Navigator.of(context).push<void>(
        MaterialPageRoute(builder: (_) => HermesGroupChatPage(group: full)),
      );
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(AppLocalizations.of(context)!.messagesLoadFailed),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen(chatMessagesProvider, (_, messages) {
      final conversation = ref.read(activeConversationProvider);
      final profile = conversation?.metadata['hermesBotProfile'];
      if (profile is String) {
        ref.read(hermesMessageActivitiesProvider.notifier).update(
          'bot:$profile',
          (
            working: messages.any((m) => m.isStreaming),
            needsYou: messages.any(
              (m) =>
                  m.metadata?['hermesApproval'] is Map &&
                      m.metadata?['hermesApproval']['state'] == 'pending' ||
                  m.metadata?['hermesDecision'] is Map &&
                      m.metadata?['hermesDecision']['state'] == 'pending',
            ),
            failed: messages.any((m) => m.metadata?['hermesError'] != null),
          ),
        );
      }
    });
    ref.listen(hermesMobileNavigationProvider, (previous, next) {
      if (previous?.conversation == true && !next.conversation) {
        ref.invalidate(hermesBotsProvider);
        ref.invalidate(hermesMessagesBotsProvider);
        ref.invalidate(hermesBotConversationsProvider);
        ref.invalidate(hermesBotLastReplyProvider);
      }
    });
    final work = ref.watch(hermesMobileNavigationProvider);
    if (work.area != HermesWorkArea.chat || work.conversation) {
      _syncSearch(false);
      // The shell owns display lifetime separately from logical navigation.
      // Retain its real list/scroll/origin elements for entry and return.
      if (work.area != HermesWorkArea.chat ||
          HermesConversationLinkScope.read(context)?.rowRect == null) {
        return const SizedBox.shrink();
      }
    }
    final service = ref.watch(hermesApiServiceProvider);
    if (!identical(service, _service)) {
      _service = service;
      ++_searchEpoch;
      _focus.unfocus();
      _debounce?.cancel();
      _search.clear();
      _query = '';
      _category = HermesSearchCategory.all;
    }
    final navigation = ref.watch(hermesMessagesNavigationProvider),
        l10n = AppLocalizations.of(context)!;
    _reduceMotion =
        context.reduceMotion ||
        ref.watch(appSettingsProvider.select((s) => s.reduceMotion));
    _syncSearch(navigation.search);
    final content = navigation.tab == HermesMessagesTab.chats
        ? _chats()
        : _bots();
    // Header, toolbar, and list keep the same ancestry in both modes.
    return Column(
      children: [
        AnimatedBuilder(
          animation: _mode,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                child: Row(
                  children: [
                    for (final tab in HermesMessagesTab.values)
                      Expanded(
                        child: Semantics(
                          selected: navigation.tab == tab,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              border: Border(
                                bottom: BorderSide(
                                  color: navigation.tab == tab
                                      ? context.conduitTheme.textPrimary
                                      : context.conduitTheme.dividerColor,
                                  width: navigation.tab == tab ? 2 : 1,
                                ),
                              ),
                            ),
                            child: TextButton(
                              key: ValueKey('messages-tab-${tab.name}'),
                              onPressed: () => ref
                                  .read(
                                    hermesMessagesNavigationProvider.notifier,
                                  )
                                  .select(tab),
                              style: TextButton.styleFrom(
                                minimumSize: const Size(48, 48),
                                foregroundColor:
                                    context.conduitTheme.textPrimary,
                              ),
                              child: Text(
                                tab == HermesMessagesTab.chats
                                    ? l10n.messagesChats
                                    : l10n.hermesBotsTitle,
                              ),
                            ),
                          ),
                        ),
                      ),
                    const HermesProfileButton(),
                  ],
                ),
              ),
              const SizedBox(height: 6),
            ],
          ),
          builder: (context, child) {
            final t = AnimationCurves.searchMode.transform(_mode.value);
            final opacity = (1 - t / .2).clamp(0.0, 1.0);
            final height = (1 - (t - .2) / .8).clamp(0.0, 1.0);
            return ExcludeFocus(
              excluding: navigation.search,
              child: ExcludeSemantics(
                excluding: navigation.search,
                child: IgnorePointer(
                  ignoring: navigation.search,
                  child: Offstage(
                    offstage: _mode.isCompleted,
                    child: ClipRect(
                      child: Align(
                        alignment: Alignment.topCenter,
                        heightFactor: height,
                        child: Opacity(opacity: opacity, child: child),
                      ),
                    ),
                  ),
                ),
              ),
            );
          },
        ),
        _searchToolbar(content.heading, navigation.tab),
        Expanded(
          child: Stack(
            fit: StackFit.expand,
            children: [
              AnimatedBuilder(
                animation: _mode,
                child: content.body,
                builder: (context, child) => Offstage(
                  offstage: navigation.search && _mode.isCompleted,
                  child: IgnorePointer(
                    ignoring: navigation.search,
                    child: ExcludeFocus(
                      excluding: navigation.search,
                      child: TickerMode(
                        enabled: !navigation.search,
                        child: child!,
                      ),
                    ),
                  ),
                ),
              ),
              if (navigation.search)
                AnimatedBuilder(
                  animation: _mode,
                  child: _searchResults(navigation.tab),
                  builder: (context, child) =>
                      Offstage(offstage: !_mode.isCompleted, child: child!),
                ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _searchToolbar(String heading, HermesMessagesTab tab) {
    final l10n = AppLocalizations.of(context)!, theme = context.conduitTheme;
    final secondaryAction = tab == HermesMessagesTab.chats
        ? (ref.watch(hermesArchivedChatsProvider).asData?.value.isNotEmpty ??
              false)
        : (ref
                  .watch(hermesMessagesBotsProvider)
                  .asData
                  ?.value
                  .any((bot) => bot.hidden) ??
              false);
    final actionsWidth = secondaryAction ? 104.0 : 52.0;
    final controlHeight = math.max(
      48.0,
      MediaQuery.textScalerOf(context).scale(16) * 1.5 + 24,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 6),
      child: LayoutBuilder(
        builder: (context, constraints) => AnimatedBuilder(
          animation: _mode,
          builder: (context, _) {
            final t = AnimationCurves.searchMode.transform(_mode.value);
            final structure = ((t - .2) / .8).clamp(0.0, 1.0);
            final headingWidth =
                math.max(0.0, constraints.maxWidth - 48 - actionsWidth) *
                (1 - structure);
            final addWidth = actionsWidth * (1 - structure);
            final opacity = (1 - t / .2).clamp(0.0, 1.0);
            // Editable text is visible only at full width. It never traverses a
            // narrowing clip; the input element/controller remain mounted.
            final fieldVisible = _searchActive && _mode.isCompleted;
            return SizedBox(
              height: controlHeight,
              child: Row(
                children: [
                  SizedBox(
                    width: headingWidth,
                    child: Opacity(
                      opacity: opacity,
                      child: ExcludeSemantics(
                        excluding: _searchActive,
                        child: Offstage(
                          offstage: structure == 1,
                          child: Text(
                            heading,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(color: theme.textSecondary),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Material(
                      key: const ValueKey('messages-search-surface'),
                      color: Color.lerp(
                        Colors.transparent,
                        theme.surfaceContainerHighest,
                        structure,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      child: Stack(
                        fit: StackFit.expand,
                        children: [
                          Align(
                            alignment: Alignment.centerLeft,
                            child: CompactIconAction(
                              key: ValueKey(
                                tab == HermesMessagesTab.chats
                                    ? 'messages-search-chats'
                                    : 'messages-search-bots',
                              ),
                              tooltip: _searchActive
                                  ? l10n.messagesSearchClose
                                  : l10n.messagesSearch,
                              onPressed: _searchActive
                                  ? _closeSearch
                                  : _startSearch,
                              icon: _searchActive
                                  ? const Icon(HermesMessageIcons.close)
                                  : const HermesSearchIcon(),
                            ),
                          ),
                          // Full-width hidden layout avoids an overflowing input at the
                          // compact endpoint, including accessibility text scales.
                          OverflowBox(
                            alignment: Alignment.centerRight,
                            minWidth: constraints.maxWidth,
                            maxWidth: constraints.maxWidth,
                            child: Offstage(
                              offstage: !fieldVisible,
                              child: ExcludeFocus(
                                excluding: !fieldVisible,
                                child: SizedBox(
                                  width: constraints.maxWidth,
                                  height: controlHeight,
                                  child: Row(
                                    children: [
                                      const SizedBox(width: 48),
                                      Expanded(
                                        child: TextField(
                                          key: const ValueKey(
                                            'messages-search-input',
                                          ),
                                          controller: _search,
                                          focusNode: _focus,
                                          onChanged: _changeQuery,
                                          textInputAction:
                                              TextInputAction.search,
                                          onSubmitted: (value) {
                                            if (_searchActive) {
                                              _debounce?.cancel();
                                              setState(
                                                () => _query = value.trim(),
                                              );
                                            }
                                          },
                                          decoration: InputDecoration(
                                            hintText: l10n.messagesSearch,
                                            hintStyle: TextStyle(
                                              color: theme.inputPlaceholder,
                                            ),
                                            filled: false,
                                            border: InputBorder.none,
                                            enabledBorder: InputBorder.none,
                                            focusedBorder: InputBorder.none,
                                            disabledBorder: InputBorder.none,
                                            errorBorder: InputBorder.none,
                                            focusedErrorBorder:
                                                InputBorder.none,
                                            contentPadding:
                                                const EdgeInsets.symmetric(
                                                  horizontal: 4,
                                                  vertical: 12,
                                                ),
                                          ),
                                        ),
                                      ),
                                      KeyedSubtree(
                                        key: _categoryAnchor,
                                        child: Tooltip(
                                          message:
                                              '${l10n.messagesCategories}: ${_categoryLabel(_category)}',
                                          child: TextButton(
                                            key: const ValueKey(
                                              'messages-search-categories',
                                            ),
                                            style: TextButton.styleFrom(
                                              minimumSize: const Size(48, 48),
                                              padding:
                                                  const EdgeInsets.symmetric(
                                                    horizontal: 10,
                                                  ),
                                              foregroundColor:
                                                  theme.textPrimary,
                                              textStyle: Theme.of(context)
                                                  .textTheme
                                                  .labelMedium,
                                            ),
                                            onPressed: () => _categories(tab),
                                            child: Row(
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                const Icon(
                                                  HermesMessageIcons.filter,
                                                  size: 18,
                                                ),
                                                const SizedBox(width: 6),
                                                Text(
                                                  _categoryLabel(_category),
                                                  key: const ValueKey(
                                                    'messages-search-category-value',
                                                  ),
                                                  maxLines: 1,
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  SizedBox(
                    width: addWidth,
                    child: Opacity(
                      opacity: opacity,
                      child: IgnorePointer(
                        ignoring: _searchActive,
                        child: ExcludeFocus(
                          excluding: _searchActive,
                          child: OverflowBox(
                            alignment: Alignment.centerRight,
                            minWidth: actionsWidth,
                            maxWidth: actionsWidth,
                            child: _actions(
                              bots: tab == HermesMessagesTab.bots,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _actions({bool bots = false}) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!bots &&
            (ref.watch(hermesArchivedChatsProvider).asData?.value.isNotEmpty ??
                false))
          CompactIconAction(
            tooltip: _showArchived ? 'Show chats' : 'Show archived chats',
            icon: Icon(
              _showArchived ? Icons.inventory_2 : Icons.inventory_2_outlined,
            ),
            onPressed: () => setState(() => _showArchived = !_showArchived),
          ),
        if (bots &&
            (ref
                    .watch(hermesMessagesBotsProvider)
                    .asData
                    ?.value
                    .any((bot) => bot.hidden) ??
                false))
          CompactIconAction(
            tooltip: ref.watch(hermesHiddenBotsVisibleProvider)
                ? 'Hide hidden bots'
                : 'Show hidden bots',
            icon: Icon(
              ref.watch(hermesHiddenBotsVisibleProvider)
                  ? Icons.visibility_off_outlined
                  : Icons.visibility_outlined,
            ),
            onPressed: () =>
                ref.read(hermesHiddenBotsVisibleProvider.notifier).toggle(),
          ),
        if (!bots)
          CompactIconAction(
            key: const ValueKey('hermes-new-conversation'),
            tooltip: l10n.newChat,
            icon: const Icon(HermesMessageIcons.add),
            onPressed: () => unawaited(startHermesMobileConversation(ref)),
          ),
        if (bots)
          CompactPopupMenu<String>(
            key: const ValueKey('messages-create-menu'),
            tooltip: l10n.messagesCreateMenu,
            icon: const Icon(HermesMessageIcons.add),
            choices: [
              CompactMenuChoice(
                'bot',
                l10n.messagesNewBot,
                icon: HermesMessageIcons.bots,
              ),
              CompactMenuChoice(
                'group',
                l10n.messagesNewGroup,
                icon: HermesMessageIcons.groups,
              ),
            ],
            onSelected: _create,
          ),
      ],
    );
  }

  ({String heading, Widget body}) _chats() {
    final l10n = AppLocalizations.of(context)!,
        sessions = _showArchived
            ? ref.watch(hermesArchivedChatsProvider)
            : ref.watch(hermesSessionsProvider);
    final bots =
        ref.watch(hermesMessagesBotsProvider).asData?.value ??
        const <HermesBot>[];
    final all = hermesRegularConversations(
      sessions.asData?.value ?? const <HermesSessionSummary>[],
      bots,
      profile:
          ref.watch(hermesApiServiceProvider)?.config.desktopProfile ??
          'default',
    );
    final now = DateTime.now(),
        locale = Localizations.localeOf(context).toString();
    final groups = groupHermesConversations(all, now);
    String heading(int i) {
      if (groups.isEmpty) return l10n.today;
      final group = groups[i];
      final date = group.date?.toLocal();
      if (date != null) {
        if (date.year == now.year &&
            date.month == now.month &&
            date.day == now.day) {
          return l10n.today;
        }
        if (date.year == now.year &&
            date.month == now.month &&
            date.day == now.day - 1) {
          return l10n.yesterday;
        }
      }
      return switch (group.kind) {
        HermesConversationPeriod.day => DateFormat.EEEE(locale).format(date!),
        HermesConversationPeriod.lastWeek => l10n.mobileLastWeek,
        HermesConversationPeriod.month => DateFormat.MMMM(locale).format(date!),
        HermesConversationPeriod.older => l10n.mobileOlderConversations,
      };
    }

    return (
      heading: _showArchived ? 'Archived' : heading(0),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(hermesSessionsProvider);
          await ref.read(hermesSessionsProvider.future);
        },
        child: sessions.when(
          loading: () => const Center(child: AdaptiveProgressIndicator()),
          error: (_, _) => HermesLoadError(
            onRetry: () => ref.invalidate(hermesSessionsProvider),
          ),
          data: (_) => ListView(
            controller: _chatScroll,
            padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
            physics: const AlwaysScrollableScrollPhysics(),
            children: [
              if (all.isEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 24),
                  child: Text(
                    l10n.mobileNoConversations,
                    style: TextStyle(color: context.conduitTheme.textSecondary),
                  ),
                ),
              for (var i = 0; i < groups.length; i++) ...[
                if (i > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 24, bottom: 4),
                    child: Text(
                      heading(i),
                      style: Theme.of(context).textTheme.labelLarge,
                    ),
                  ),
                for (final session in groups[i].sessions)
                  HermesMessageRow(
                    key: ValueKey('messages-chat-${session.id}'),
                    conversationId: session.id,
                    title: session.title,
                    preview: session.preview,
                    date:
                        session.updatedAt != null &&
                            now.difference(session.updatedAt!.toLocal()) <
                                const Duration(hours: 12)
                        ? session.updatedAt
                        : null,
                    trailing: HermesChatActions(
                      session: session,
                      menuKey: _chatMenuKey(session.id),
                    ),
                    onLongPress: () =>
                        _chatMenuKey(session.id).currentState?.showButtonMenu(),
                    onOpen: () => openHermesSession(context, ref, session),
                  ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  ({String heading, Widget body}) _bots() {
    final l10n = AppLocalizations.of(context)!,
        conversations = ref.watch(hermesBotConversationsProvider),
        groups = ref.watch(hermesBotGroupsProvider);
    final rows =
        <({DateTime? date, Widget row})>[
          for (final entry
              in conversations.asData?.value.rows ?? <HermesBotConversation>[])
            if (!entry.bot.hidden || ref.watch(hermesHiddenBotsVisibleProvider))
              (date: entry.lastActive, row: _botRow(entry)),
          for (final group in groups.asData?.value ?? <HermesBotGroup>[])
            (date: group.lastActive, row: _groupRow(group)),
        ]..sort(
          (a, b) =>
              (b.date ?? DateTime(1970)).compareTo(a.date ?? DateTime(1970)),
        );
    return (
      heading: '',
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(hermesBotsProvider);
          ref.invalidate(hermesMessagesBotsProvider);
          ref.invalidate(hermesBotGroupsProvider);
          ref.invalidate(hermesBotConversationsProvider);
          await ref.read(hermesBotConversationsProvider.future);
        },
        child: ListView(
          controller: _botScroll,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          physics: const AlwaysScrollableScrollPhysics(),
          children: [
            if (conversations.isLoading || groups.isLoading)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Center(child: AdaptiveProgressIndicator()),
              ),
            if (conversations.hasError || groups.hasError)
              HermesLoadError(
                onRetry: () {
                  ref.invalidate(hermesMessagesBotsProvider);
                  ref.invalidate(hermesBotGroupsProvider);
                  ref.invalidate(hermesBotConversationsProvider);
                },
              ),
            if (!conversations.isLoading &&
                !groups.isLoading &&
                !conversations.hasError &&
                !groups.hasError &&
                rows.isEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 24),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(l10n.messagesNoBots),
                    const SizedBox(height: 12),
                    FilledButton.icon(
                      key: const ValueKey('messages-empty-create-bot'),
                      onPressed: () => _create('bot'),
                      icon: const Icon(HermesMessageIcons.add, size: 20),
                      label: Text(l10n.messagesNewBot),
                    ),
                  ],
                ),
              ),
            if ((conversations.asData?.value.failedProfiles ?? 0) > 0)
              Text(
                l10n.messagesPartialSearch,
                style: TextStyle(color: context.conduitTheme.textSecondary),
              ),
            for (final entry in rows) entry.row,
          ],
        ),
      ),
    );
  }

  Widget _botRow(HermesBotConversation row, {String? preview}) {
    return HermesBotConversationRow(row: row, preview: preview);
  }

  Widget _groupRow(HermesBotGroup group) => HermesMessageRow(
    key: ValueKey('messages-group-${group.identity}'),
    title: group.name,
    date: group.lastActive,
    leading: const Icon(HermesMessageIcons.groups, size: 44),
    trailing: Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        HermesConversationStatus(
          identity: 'group:${group.identity}',
          lastActive: group.lastActive,
        ),
        HermesGroupActions(group: group),
      ],
    ),
    onOpen: () => _openGroup(group),
  );
  String _categoryLabel(HermesSearchCategory category) {
    final l10n = AppLocalizations.of(context)!;
    return switch (category) {
      HermesSearchCategory.all => l10n.messagesAll,
      HermesSearchCategory.messages => l10n.messagesHomeTitle,
      HermesSearchCategory.bots => l10n.hermesBotsTitle,
      HermesSearchCategory.groups => l10n.messagesGroupChats,
      HermesSearchCategory.files => l10n.files,
      HermesSearchCategory.routines => l10n.messagesRoutines,
    };
  }

  IconData _categoryIcon(HermesSearchCategory category) => switch (category) {
    HermesSearchCategory.bots => HermesMessageIcons.bots,
    HermesSearchCategory.groups => HermesMessageIcons.groups,
    HermesSearchCategory.files => HermesMessageIcons.file,
    HermesSearchCategory.routines => HermesMessageIcons.routines,
    _ => HermesMessageIcons.messages,
  };
  Widget _searchResults(HermesMessagesTab tab) {
    final l10n = AppLocalizations.of(context)!, theme = context.conduitTheme;
    final searchKey = (tab: tab, query: _query);
    final results = _query.isEmpty
        ? const AsyncData<HermesMessagesSearchResults>(
            HermesMessagesSearchResults(),
          )
        : ref.watch(hermesMessagesSearchProvider(searchKey));
    return _query.isEmpty
        ? const SizedBox.shrink()
        : results.when(
            loading: () => const Center(child: AdaptiveProgressIndicator()),
            error: (_, _) => HermesLoadError(
              onRetry: () =>
                  ref.invalidate(hermesMessagesSearchProvider(searchKey)),
            ),
            data: (result) {
              final visible = <Widget>[];
              if ({
                HermesSearchCategory.all,
                HermesSearchCategory.messages,
              }.contains(_category)) {
                for (final entry in result.conversations) {
                  visible.add(
                    entry.bot == null
                        ? HermesMessageRow(
                            title: entry.session.title,
                            preview: entry.match,
                            date: entry.session.updatedAt,
                            onOpen: () =>
                                openHermesSession(context, ref, entry.session),
                          )
                        : _botRow(
                            HermesBotConversation(
                              bot: entry.bot!,
                              session: entry.session,
                            ),
                            preview: entry.match,
                          ),
                  );
                }
              }
              if ({
                HermesSearchCategory.all,
                HermesSearchCategory.bots,
              }.contains(_category)) {
                for (final bot in result.bots) {
                  if (_category == HermesSearchCategory.bots ||
                      !result.conversations.any(
                        (c) => c.bot?.name == bot.name,
                      )) {
                    visible.add(_botRow(HermesBotConversation(bot: bot)));
                  }
                }
              }
              if ({
                HermesSearchCategory.all,
                HermesSearchCategory.messages,
                HermesSearchCategory.groups,
              }.contains(_category)) {
                for (final group in result.groups) {
                  visible.add(_groupRow(group));
                }
              }
              if ({
                HermesSearchCategory.all,
                HermesSearchCategory.files,
              }.contains(_category)) {
                for (final entry in result.files) {
                  visible.add(
                    HermesMessageRow(
                      title: entry.file.name,
                      preview: entry.file.session.title,
                      leading: const Icon(HermesMessageIcons.file, size: 28),
                      onOpen: () async {
                        if (entry.bot != null) {
                          ref
                              .read(hermesMessagesBackendProvider)
                              ?.bindBotSession(
                                entry.bot!.name,
                                entry.file.session.id,
                              );
                        }
                        await showHermesFilePreview(context, ref, entry.file);
                      },
                    ),
                  );
                }
              }
              if ({
                HermesSearchCategory.all,
                HermesSearchCategory.routines,
              }.contains(_category)) {
                for (final job in result.routines) {
                  visible.add(
                    HermesMessageRow(
                      title: job.displayName,
                      preview: job.prompt,
                      leading: const Icon(
                        HermesMessageIcons.routines,
                        size: 28,
                      ),
                      onOpen: () async {
                        await Navigator.of(context).push<void>(
                          MaterialPageRoute(
                            builder: (_) => HermesRoutineDetailPage(job: job),
                          ),
                        );
                      },
                    ),
                  );
                }
              }
              return ListView(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                children: [
                  Semantics(
                    liveRegion: true,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Text(
                        result.searching
                            ? l10n.messagesSearching
                            : visible.isEmpty
                            ? l10n.mobileNoSearchResults
                            : l10n.messagesResultCount(visible.length),
                        style: TextStyle(color: theme.textSecondary),
                      ),
                    ),
                  ),
                  if (result.failed > 0)
                    TextButton(
                      onPressed: () => ref.invalidate(
                        hermesMessagesSearchProvider(searchKey),
                      ),
                      child: Text(l10n.messagesPartialSearch),
                    ),
                  ...visible,
                ],
              );
            },
          );
  }
}

class HermesMessageRow extends StatefulWidget {
  const HermesMessageRow({
    super.key,
    required this.title,
    required this.onOpen,
    this.preview,
    this.date,
    this.leading,
    this.conversationId,
    this.trailing,
    this.onLongPress,
  });
  final String? conversationId;
  final String title;
  final String? preview;
  final DateTime? date;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onLongPress;
  final Future<void> Function() onOpen;
  @override
  State<HermesMessageRow> createState() => _HermesMessageRowState();
}

class _HermesMessageRowState extends State<HermesMessageRow> {
  bool _opening = false;
  final _rowKey = GlobalKey();
  final _titleKey = GlobalKey();
  HermesConversationLink? _link;
  bool _titleHidden = false;

  void _visibilityChanged() {
    final hidden = _link?.hides(widget.conversationId) == true;
    if (mounted && hidden != _titleHidden) {
      setState(() => _titleHidden = hidden);
    }
  }

  void _syncLink() {
    final next = HermesConversationLinkScope.read(context);
    if (!identical(_link, next)) {
      _link?.removeListener(_visibilityChanged);
      _link = next;
      _link?.addListener(_visibilityChanged);
    }
    _titleHidden = _link?.hides(widget.conversationId) == true;
    _registerOrigin();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncLink();
  }

  @override
  void didUpdateWidget(covariant HermesMessageRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.conversationId != widget.conversationId &&
        _link?.origins[oldWidget.conversationId]?.row == _rowKey) {
      _link?.origins.remove(oldWidget.conversationId);
    }
    _syncLink();
  }

  void _registerOrigin() {
    if (widget.conversationId != null) {
      _link?.origins[widget.conversationId!] = (
        row: _rowKey,
        title: _titleKey,
        style: Theme.of(context).textTheme.bodyLarge
            ?.copyWith(fontWeight: FontWeight.w500),
      );
    }
  }

  @override
  void dispose() {
    _link?.removeListener(_visibilityChanged);
    final id = widget.conversationId;
    if (id != null && _link?.origins[id]?.row == _rowKey) {
      _link?.origins.remove(id);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = context.conduitTheme, l10n = AppLocalizations.of(context)!;
    final preview = hermesMessagePreview(widget.title, widget.preview);
    final time = hermesMessageTimestamp(
      widget.date,
      DateTime.now(),
      Localizations.localeOf(context).toString(),
      yesterday: l10n.yesterday,
    );
    return Semantics(
      button: true,
      label:
          '${widget.title}${preview == null ? '' : ', $preview'}${time.isEmpty ? '' : ', $time'}',
      child: InkWell(
        onLongPress: widget.onLongPress,
        onTap: _opening
            ? null
            : () async {
                setState(() => _opening = true);
                try {
                  await widget.onOpen();
                } finally {
                  if (mounted) setState(() => _opening = false);
                }
              },
        child: Container(
          key: _rowKey,
          constraints: BoxConstraints(
            minHeight: widget.leading != null || preview != null ? 72 : 56,
          ),
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            border: Border(bottom: BorderSide(color: theme.dividerColor)),
          ),
          child: Row(
            children: [
              if (widget.leading != null) ...[
                SizedBox(
                  width: 48,
                  height: 48,
                  child: Center(child: widget.leading),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Opacity(
                            key: _titleKey,
                            opacity: _titleHidden ? 0 : 1,
                            alwaysIncludeSemantics: true,
                            child: Text(
                              widget.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodyLarge
                                  ?.copyWith(fontWeight: FontWeight.w500),
                            ),
                          ),
                        ),
                        if (time.isNotEmpty) ...[
                          const SizedBox(width: 8),
                          Text(
                            time,
                            style: Theme.of(context).textTheme.labelSmall
                                ?.copyWith(color: theme.textSecondary),
                          ),
                        ],
                      ],
                    ),
                    if (preview != null) ...[
                      const SizedBox(height: 4),
                      Text(
                        preview,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.bodyMedium
                            ?.copyWith(color: theme.textSecondary),
                      ),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (_opening)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: AdaptiveProgressIndicator(),
                )
              else if (widget.trailing != null)
                widget.trailing!
              else
                Icon(
                  HermesMessageIcons.next,
                  size: 16,
                  color: theme.textSecondary,
                ),
            ],
          ),
        ),
      ),
    );
  }
}

class HermesConversationStatus extends ConsumerWidget {
  const HermesConversationStatus({
    super.key,
    required this.identity,
    this.lastActive,
  });
  final String identity;
  final DateTime? lastActive;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final activity = ref.watch(
      hermesMessageActivitiesProvider.select((values) => values[identity]),
    );
    final receipts =
        ref.watch(hermesMessageReadReceiptsProvider).asData?.value ??
        const <String, int>{};
    if (activity?.needsYou == true) {
      return const Tooltip(
        message: 'Needs you',
        child: Icon(Icons.pending_actions, size: 16),
      );
    }
    if (activity?.failed == true) {
      return Tooltip(
        message: 'Response failed',
        child: Icon(
          Icons.error_outline,
          size: 16,
          color: context.conduitTheme.error,
        ),
      );
    }
    if (activity?.working == true) {
      return const Tooltip(
        message: 'Working',
        child: SizedBox(
          width: 16,
          height: 16,
          child: AdaptiveProgressIndicator(),
        ),
      );
    }
    if (hermesMessageIsUnread(receipts, identity, lastActive)) {
      return Semantics(
        label: 'Unread',
        child: Container(
          width: 8,
          height: 8,
          margin: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            color: context.conduitTheme.textPrimary,
            shape: BoxShape.circle,
          ),
        ),
      );
    }
    return const SizedBox.shrink();
  }
}

class HermesBotConversationRow extends ConsumerWidget {
  const HermesBotConversationRow({super.key, required this.row, this.preview});
  final HermesBotConversation row;
  final String? preview;
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final bot = row.bot;
    final avatar = bot.hasAvatar
        ? ref.watch(hermesMessageAvatarProvider(bot.name)).asData?.value
        : null;
    final reply =
        preview ??
        (row.session == null
            ? bot.preview
            : ref
                  .watch(
                    hermesBotLastReplyProvider((
                      profile: bot.name,
                      id: row.session!.id,
                    )),
                  )
                  .asData
                  ?.value);
    return HermesMessageRow(
      key: ValueKey(
        'messages-bot-${bot.name}-${row.session?.id ?? 'canonical'}',
      ),
      title: bot.title,
      preview: reply,
      date: row.lastActive,
      leading: HermesBotAvatar(
        size: 48,
        label: bot.title,
        shape: bot.avatarShape,
        color: bot.avatarColor,
        imageUrl: avatar,
        imageKind: bot.avatarImageKind,
        icon: bot.icon,
      ),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          HermesConversationStatus(
            identity: 'bot:${bot.name}',
            lastActive: row.lastActive,
          ),
          HermesBotActions(row: row),
        ],
      ),
      onOpen: () => openHermesBotConversation(context, ref, row),
    );
  }
}
