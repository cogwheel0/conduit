import 'dart:async';

import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/services/navigation_service.dart';
import '../../../shared/services/user_friendly_error_handler.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/platform_page_route.dart';
import '../../../shared/widgets/platform_ui/platform_ui.dart';
import '../../../shared/widgets/platform_ui/vocabulary.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/sidebar_layout_contract.dart';
import '../../navigation/providers/conversation_selection_provider.dart';
import '../providers/library_search_providers.dart';

typedef _Selection = ({LibrarySearchSource source, LibrarySearchResult result});

Future<void> openLibrarySearch(BuildContext context, WidgetRef ref) async {
  final owner = ref.read(openWebUiAuthSessionEpochProvider);
  final api = ref.read(apiServiceProvider);
  final database = ref.read(appDatabaseProvider);
  final selection = await Navigator.of(context, rootNavigator: true)
      .push<_Selection>(
        buildPlatformPageRoute<_Selection>(
          fullscreenDialog: true,
          builder: (_) => const LibrarySearchPage(),
        ),
      );
  if (selection == null ||
      !context.mounted ||
      ref.read(openWebUiAuthSessionEpochProvider) != owner ||
      ref.read(apiServiceProvider) != api ||
      ref.read(appDatabaseProvider) != database) {
    return;
  }

  final conversation = selection.result.conversation;
  if (conversation != null) {
    final routeRevision = NavigationService.currentRouteRevision;
    final selected = await ref
        .read(conversationSelectionProvider.notifier)
        .select(conversation);
    if (!context.mounted ||
        NavigationService.currentRouteRevision != routeRevision) {
      return;
    }
    if (selected.disposition == ConversationSelectionDisposition.failed) {
      UserFriendlyErrorHandler().showErrorSnackbar(context, selected.error);
      return;
    }
    if (selected.disposition != ConversationSelectionDisposition.committed) {
      return;
    }
    NavigationService.router.go(Routes.chat);
  } else if (selection.source == LibrarySearchSource.folders) {
    ref.read(pendingFolderIdProvider.notifier).clear();
    NavigationService.router.goNamed(
      RouteNames.folder,
      pathParameters: {'id': selection.result.id},
    );
  } else {
    NavigationService.router.goNamed(
      RouteNames.noteEditor,
      pathParameters: {'id': selection.result.id},
    );
  }
  if (context.mounted) closeSidebarDrawerIfOverlay(context);
}

/// Full-screen search is independent of the sidebar's legacy inline field.
class LibrarySearchPage extends ConsumerStatefulWidget {
  const LibrarySearchPage({super.key});

  @override
  ConsumerState<LibrarySearchPage> createState() => _LibrarySearchPageState();
}

class _LibrarySearchPageState extends ConsumerState<LibrarySearchPage> {
  final _controller = TextEditingController();
  final _focus = FocusNode();
  Timer? _debounce;
  String _query = '';
  LibrarySearchSource? _scope;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _changeQuery(String value) {
    _debounce?.cancel();
    // Clear old results immediately so they cannot be opened under new text.
    setState(() => _query = '');
    if (value.trim().isEmpty) return;
    _debounce = Timer(const Duration(milliseconds: 250), () {
      if (mounted) setState(() => _query = value.trim());
    });
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final owner = ref.watch(openWebUiAuthSessionEpochProvider);
    final api = ref.watch(apiServiceProvider);
    final database = ref.watch(appDatabaseProvider);
    final sources = [
      LibrarySearchSource.chats,
      LibrarySearchSource.localChats,
      if (ref.watch(foldersAvailableProvider)) LibrarySearchSource.folders,
      if (ref.watch(openWebUiAccountAvailableProvider) &&
          ref.watch(notesFeatureEnabledProvider))
        LibrarySearchSource.notes,
    ];
    final scope = sources.contains(_scope) ? _scope : null;
    final visibleSources = sources
        .where(
          (source) =>
              scope == null ||
              source == scope ||
              (scope == LibrarySearchSource.chats &&
                  source == LibrarySearchSource.localChats),
        )
        .toList();
    final noResults =
        _query.isNotEmpty &&
        visibleSources.every((source) {
          final page = ref.watch(
            librarySearchPageProvider((source: source, query: _query, page: 1)),
          );
          return !page.isLoading &&
              !page.hasError &&
              page.asData?.value.items.isEmpty == true;
        });

    return Focus(
      canRequestFocus: false,
      includeSemantics: false,
      onKeyEvent: (_, event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          unawaited(Navigator.of(context).maybePop());
          return KeyEventResult.handled;
        }
        return KeyEventResult.ignored;
      },
      child: AdaptiveScaffold(
        key: const ValueKey('library-search-page'),
        body: SafeArea(
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Row(
                      children: [
                        for (final filter in <LibrarySearchSource?>[
                          null,
                          ...sources.where(
                            (s) => s != LibrarySearchSource.localChats,
                          ),
                        ])
                          Padding(
                            padding: const EdgeInsetsDirectional.only(end: 8),
                            child: AdaptiveChip.choice(
                              key: ValueKey(
                                'search-filter-${filter?.name ?? 'all'}',
                              ),
                              label: Text(
                                filter == null
                                    ? l10n.librarySearchAll
                                    : _sourceLabel(l10n, filter),
                              ),
                              selected: scope == filter,
                              showCheckmark: false,
                              side: BorderSide.none,
                              shape: const StadiumBorder(),
                              selectedColor: theme.surfaceContainer,
                              labelStyle: TextStyle(color: theme.textPrimary),
                              backgroundColor: const Color(0x00000000),
                              onSelected: (_) =>
                                  setState(() => _scope = filter),
                            ),
                          ),
                      ],
                    ),
                  ),
                  Expanded(
                    child: _query.isEmpty
                        ? _SearchMessage(
                            title: l10n.librarySearchTitle,
                            detail: _controller.text.trim().isEmpty
                                ? l10n.librarySearchHint
                                : l10n.librarySearching,
                          )
                        : noResults
                        ? _SearchMessage(
                            title: l10n.noResults,
                            detail: l10n.tryDifferentSearch,
                          )
                        : CustomScrollView(
                            key: ValueKey((
                              _query,
                              scope,
                              api,
                              database,
                              owner,
                            )),
                            keyboardDismissBehavior:
                                ScrollViewKeyboardDismissBehavior.onDrag,
                            slivers: [
                              for (final source in visibleSources)
                                _SearchSection(source: source, query: _query),
                            ],
                          ),
                  ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 12, 8),
                    child: Row(
                      children: [
                        Expanded(
                          child: ConduitGlassSearchField(
                            controller: _controller,
                            focusNode: _focus,
                            hintText: l10n.librarySearchTitle,
                            query: _controller.text,
                            onChanged: _changeQuery,
                            onClear: () {
                              _controller.clear();
                              _changeQuery('');
                              _focus.requestFocus();
                            },
                          ),
                        ),
                        const SizedBox(width: 8),
                        AdaptiveButton.icon(
                          key: const ValueKey('library-search-close'),
                          semanticLabel: l10n.close,
                          icon: Icons.close,
                          style: AdaptiveButtonStyle.gray,
                          size: AdaptiveButtonSize.large,
                          minSize: const Size.square(48),
                          padding: EdgeInsets.zero,
                          useSmoothRectangleBorder: false,
                          borderRadius: BorderRadius.circular(24),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String _sourceLabel(AppLocalizations l10n, LibrarySearchSource source) =>
    switch (source) {
      LibrarySearchSource.chats => l10n.sidebarChatsTab,
      LibrarySearchSource.localChats => l10n.librarySearchOnDevice,
      LibrarySearchSource.folders => l10n.folders,
      LibrarySearchSource.notes => l10n.notes,
    };

class _SearchMessage extends StatelessWidget {
  const _SearchMessage({required this.title, required this.detail});
  final String title;
  final String detail;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search,
            size: 40,
            color: context.conduitTheme.textSecondary,
          ),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 6),
          Text(
            detail,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.conduitTheme.textSecondary),
          ),
        ],
      ),
    ),
  );
}

class _SearchSection extends ConsumerStatefulWidget {
  const _SearchSection({required this.source, required this.query});
  final LibrarySearchSource source;
  final String query;

  @override
  ConsumerState<_SearchSection> createState() => _SearchSectionState();
}

class _SearchSectionState extends ConsumerState<_SearchSection> {
  int _pages = 1;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final seen = <String>{};
    final pages = [
      for (var page = 1; page <= _pages; page++)
        ref.watch(
          librarySearchPageProvider((
            source: widget.source,
            query: widget.query,
            page: page,
          )),
        ),
    ];
    final items = [
      for (final page in pages)
        if (!page.isLoading && !page.hasError)
          ...?page.asData?.value.items.where((item) => seen.add(item.id)),
    ];
    final last = pages.last;
    if (items.isEmpty && !last.isLoading && !last.hasError) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    return SliverMainAxisGroup(
      slivers: [
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(24, 18, 24, 6),
            child: Text(
              _sourceLabel(l10n, widget.source),
              style: Theme.of(context).textTheme.labelLarge,
            ),
          ),
        ),
        SliverList.builder(
          itemCount: items.length,
          itemBuilder: (context, index) => _SearchTile(
            source: widget.source,
            query: widget.query,
            result: items[index],
          ),
        ),
        SliverToBoxAdapter(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: last.isLoading
                ? const Center(
                    child: Padding(
                      padding: EdgeInsets.all(12),
                      child: SizedBox.square(
                        dimension: 18,
                        child: AdaptiveProgressIndicator(strokeWidth: 2),
                      ),
                    ),
                  )
                : last.hasError
                ? AdaptiveButton(
                    style: AdaptiveButtonStyle.plain,
                    label: '${l10n.librarySearchFailed} · ${l10n.retry}',
                    onPressed: () => ref.invalidate(
                      librarySearchPageProvider((
                        source: widget.source,
                        query: widget.query,
                        page: _pages,
                      )),
                    ),
                  )
                : last.asData?.value.hasMore == true
                ? AdaptiveButton(
                    style: AdaptiveButtonStyle.plain,
                    key: ValueKey('search-more-${widget.source.name}'),
                    onPressed: () => setState(() => _pages++),
                    label: l10n.librarySearchMore,
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}

class _SearchTile extends ConsumerWidget {
  const _SearchTile({
    required this.source,
    required this.query,
    required this.result,
  });
  final LibrarySearchSource source;
  final String query;
  final LibrarySearchResult result;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rawExcerpt =
        result.excerpt ??
        (source == LibrarySearchSource.chats
            ? ref
                  .watch(
                    libraryChatSnippetProvider((id: result.id, query: query)),
                  )
                  .asData
                  ?.value
            : null);
    final excerpt = rawExcerpt == null
        ? null
        : searchExcerpt(rawExcerpt, query);
    return AdaptiveListTile(
      key: ValueKey('search-result-${source.name}-${result.id}'),
      backgroundColor: const Color(0x00000000),
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
      hideBottomDivider: true,
      leading: Icon(
        switch (source) {
          LibrarySearchSource.folders => Icons.folder_outlined,
          LibrarySearchSource.notes => Icons.description_outlined,
          _ => Icons.chat_bubble_outline,
        },
        color: context.conduitTheme.textSecondary,
        size: 22,
      ),
      title: _highlight(
        context,
        result.title,
        query,
        maxLines: 2,
        style: Theme.of(context).textTheme.bodyLarge,
      ),
      subtitle: excerpt == null || excerpt.isEmpty
          ? null
          : _highlight(
              context,
              excerpt,
              query,
              maxLines: 2,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: context.conduitTheme.textSecondary,
                height: 1.35,
              ),
            ),
      onTap: () =>
          Navigator.of(context)
              .pop<_Selection>((source: source, result: result)),
    );
  }
}

Widget _highlight(
  BuildContext context,
  String text,
  String query, {
  required int maxLines,
  TextStyle? style,
}) {
  final spans = <TextSpan>[];
  var start = 0;
  for (final match in RegExp(
    RegExp.escape(query),
    caseSensitive: false,
  ).allMatches(text)) {
    spans.add(TextSpan(text: text.substring(start, match.start)));
    spans.add(
      TextSpan(
        text: match.group(0),
        style: TextStyle(
          color: Theme.of(context).colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
    start = match.end;
  }
  spans.add(TextSpan(text: text.substring(start)));
  return Text.rich(
    TextSpan(children: spans),
    style: style,
    maxLines: maxLines,
    overflow: TextOverflow.ellipsis,
  );
}
