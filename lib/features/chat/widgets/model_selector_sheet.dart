import 'dart:async';
import 'dart:io' show Platform;

import 'package:conduit/l10n/app_localizations.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show ScrollCacheExtent;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/models/model.dart';
import '../../../core/providers/app_providers.dart';
import '../../../core/utils/model_icon_utils.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/utils/conversation_context_menu.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/modal_safe_area.dart';
import '../../../shared/widgets/model_list_tile.dart';
import '../../../shared/widgets/sheet_handle.dart';

List<Model> sortModelsWithPinnedOrder(
  List<Model> models,
  List<String> pinnedModelIds,
) {
  if (models.isEmpty || pinnedModelIds.isEmpty) {
    return List<Model>.of(models, growable: false);
  }

  final pinnedOrder = <String, int>{};
  for (final modelId in pinnedModelIds) {
    final trimmed = modelId.trim();
    if (trimmed.isEmpty || pinnedOrder.containsKey(trimmed)) {
      continue;
    }
    pinnedOrder[trimmed] = pinnedOrder.length;
  }

  if (pinnedOrder.isEmpty) {
    return List<Model>.of(models, growable: false);
  }

  final pinned = <Model>[];
  final unpinned = <Model>[];
  for (final model in models) {
    if (pinnedOrder.containsKey(model.id)) {
      pinned.add(model);
    } else {
      unpinned.add(model);
    }
  }

  pinned.sort((a, b) => pinnedOrder[a.id]!.compareTo(pinnedOrder[b.id]!));
  return [...pinned, ...unpinned];
}

/// Bottom sheet for selecting a model from the available list.
class ModelSelectorSheet extends ConsumerStatefulWidget {
  /// The full list of models to choose from.
  final List<Model> models;

  const ModelSelectorSheet({super.key, required this.models});

  @override
  ConsumerState<ModelSelectorSheet> createState() => ModelSelectorSheetState();
}

/// State for [ModelSelectorSheet].
class ModelSelectorSheetState extends ConsumerState<ModelSelectorSheet> {
  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';
  List<Model> _filteredModels = [];
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _filteredModels = widget.models;
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  void _filterModels(String query) {
    setState(() => _searchQuery = query);

    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 160), () {
      if (!mounted) return;

      final normalized = query.trim().toLowerCase();
      Iterable<Model> list = widget.models;

      if (normalized.isNotEmpty) {
        list = list.where((model) {
          final name = model.name.toLowerCase();
          final id = model.id.toLowerCase();
          final tags = model.modelTags.map((tag) => tag.toLowerCase());
          return name.contains(normalized) ||
              id.contains(normalized) ||
              tags.any((tag) => tag.contains(normalized));
        });
      }

      setState(() {
        _filteredModels = list.toList();
      });
    });
  }

  Future<void> _togglePinnedModel(String modelId) {
    return ref
        .read(personalizationSettingsProvider.notifier)
        .togglePinnedModel(modelId);
  }

  @override
  Widget build(BuildContext context) {
    final selectedModelId = ref.watch(selectedModelProvider)?.id;
    final pinnedModelIds = ref.watch(effectivePinnedModelIdsProvider);
    final canTogglePinnedModels = ref.watch(canTogglePinnedModelsProvider);
    final displayedModels = sortModelsWithPinnedOrder(
      _filteredModels,
      pinnedModelIds,
    );
    final api = ref.watch(apiServiceProvider);
    final l10n = AppLocalizations.of(context)!;

    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => Navigator.of(context).maybePop(),
            child: const SizedBox.shrink(),
          ),
        ),
        DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.75,
          maxChildSize: 0.92,
          minChildSize: 0.45,
          builder: (context, scrollController) {
            return Container(
              decoration: BoxDecoration(
                color: context.conduitTheme.surfaceBackground,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(AppBorderRadius.bottomSheet),
                ),
                border: Border.all(
                  color: context.conduitTheme.dividerColor,
                  width: BorderWidth.regular,
                ),
                boxShadow: ConduitShadows.modal(context),
              ),
              child: ModalSheetSafeArea(
                padding: const EdgeInsets.symmetric(
                  horizontal: Spacing.modalPadding,
                  vertical: Spacing.modalPadding,
                ),
                child: Column(
                  children: [
                    const SheetHandle(),
                    Expanded(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: Scrollbar(
                              controller: scrollController,
                              child: displayedModels.isEmpty
                                  ? Center(
                                      child: Column(
                                        mainAxisAlignment:
                                            MainAxisAlignment.center,
                                        children: [
                                          Icon(
                                            Platform.isIOS
                                                ? CupertinoIcons.search_circle
                                                : Icons.search_off,
                                            size: 48,
                                            color: context
                                                .conduitTheme
                                                .iconSecondary,
                                          ),
                                          const SizedBox(height: Spacing.md),
                                          Text(
                                            'No results',
                                            style: AppTypography.bodyLargeStyle
                                                .copyWith(
                                                  color: context
                                                      .conduitTheme
                                                      .textSecondary,
                                                ),
                                          ),
                                        ],
                                      ),
                                    )
                                  : ListView.builder(
                                      controller: scrollController,
                                      padding: const EdgeInsets.only(top: 72),
                                      scrollCacheExtent:
                                          const ScrollCacheExtent.pixels(400),
                                      itemCount: displayedModels.length,
                                      itemBuilder: (context, index) {
                                        final model = displayedModels[index];
                                        final isSelected =
                                            selectedModelId == model.id;
                                        final isPinned = pinnedModelIds
                                            .contains(model.id);
                                        final iconUrl =
                                            resolveModelIconUrlForModel(
                                              api,
                                              model,
                                            );

                                        return ConduitContextMenu(
                                          actions: canTogglePinnedModels
                                              ? [
                                                  ConduitContextMenuAction(
                                                    cupertinoIcon: isPinned
                                                        ? CupertinoIcons
                                                              .pin_slash
                                                        : CupertinoIcons.pin,
                                                    materialIcon: isPinned
                                                        ? Icons
                                                              .push_pin_outlined
                                                        : Icons
                                                              .push_pin_rounded,
                                                    label: isPinned
                                                        ? l10n.unpin
                                                        : l10n.pin,
                                                    onSelected: () async {
                                                      await _togglePinnedModel(
                                                        model.id,
                                                      );
                                                    },
                                                  ),
                                                ]
                                              : const [],
                                          child: ModelListTile(
                                            model: model,
                                            isSelected: isSelected,
                                            isPinned: isPinned,
                                            iconUrl: iconUrl,
                                            onTap: () {
                                              ref
                                                  .read(
                                                    selectedModelProvider
                                                        .notifier,
                                                  )
                                                  .set(model);
                                              Navigator.pop(context);
                                            },
                                          ),
                                        );
                                      },
                                    ),
                            ),
                          ),
                          Positioned(
                            top: 0,
                            left: 0,
                            right: 0,
                            child: Container(
                              decoration: BoxDecoration(
                                gradient: LinearGradient(
                                  begin: Alignment.topCenter,
                                  end: Alignment.bottomCenter,
                                  stops: const [0.0, 0.65, 1.0],
                                  colors: [
                                    context.conduitTheme.surfaceBackground,
                                    context.conduitTheme.surfaceBackground
                                        .withValues(alpha: 0.9),
                                    context.conduitTheme.surfaceBackground
                                        .withValues(alpha: 0.0),
                                  ],
                                ),
                              ),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  const SizedBox(height: Spacing.sm),
                                  ConduitGlassSearchField(
                                    controller: _searchController,
                                    hintText: AppLocalizations.of(
                                      context,
                                    )!.searchModels,
                                    onChanged: _filterModels,
                                    query: _searchQuery,
                                    onClear: () {
                                      _searchController.clear();
                                      _filterModels('');
                                    },
                                  ),
                                  const SizedBox(height: Spacing.md),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            );
          },
        ),
      ],
    );
  }
}
