import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:super_sliver_list/super_sliver_list.dart';

import 'skeleton_loader.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'conduit_loading.dart';

/// Sliver version of an optimized list for use in CustomScrollView.
class OptimizedSliverList<T> extends ConsumerWidget {
  final List<T> items;
  final Widget Function(BuildContext context, T item, int index) itemBuilder;
  final Widget? loadingWidget;
  final Widget? emptyWidget;
  final String? emptyMessage;
  final bool isLoading;
  final bool hasMore;
  final VoidCallback? onLoadMore;
  final bool addAutomaticKeepAlives;
  final bool addRepaintBoundaries;
  final ListController? listController;
  final ExtentEstimationProvider? extentEstimation;
  final ExtentPrecalculationPolicy? extentPrecalculationPolicy;
  final bool delayPopulatingCacheArea;
  final bool layoutKeptAliveChildren;
  final bool useSuperSliverList;

  const OptimizedSliverList({
    super.key,
    required this.items,
    required this.itemBuilder,
    this.loadingWidget,
    this.emptyWidget,
    this.emptyMessage,
    this.isLoading = false,
    this.hasMore = false,
    this.onLoadMore,
    this.addAutomaticKeepAlives = true,
    this.addRepaintBoundaries = true,
    this.listController,
    this.extentEstimation,
    this.extentPrecalculationPolicy,
    this.delayPopulatingCacheArea = true,
    this.layoutKeptAliveChildren = false,
    this.useSuperSliverList = true,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Loading state
    if (isLoading && items.isEmpty) {
      return SliverToBoxAdapter(
        child: loadingWidget ?? _buildDefaultLoadingWidget(),
      );
    }

    // Empty state
    if (items.isEmpty) {
      return SliverToBoxAdapter(
        child:
            emptyWidget ??
            Builder(
              builder: (context) {
                final l10n = AppLocalizations.of(context)!;
                return ImprovedEmptyState(
                  title: l10n.noItems,
                  subtitle: emptyMessage ?? l10n.noItemsToDisplay,
                  icon: Icons.inbox_outlined,
                );
              },
            ),
      );
    }

    NullableIndexedWidgetBuilder builder = (context, index) {
      if (index >= items.length) {
        if (hasMore) {
          // Trigger pagination once this placeholder is built.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            onLoadMore?.call();
          });
          return Container(
            padding: const EdgeInsets.all(16.0),
            alignment: Alignment.center,
            child: const CircularProgressIndicator(),
          );
        }
        return null;
      }

      final item = items[index];
      return itemBuilder(context, item, index);
    };

    if (!useSuperSliverList) {
      return SliverList(
        delegate: SliverChildBuilderDelegate(
          builder,
          childCount: items.length + (hasMore ? 1 : 0),
          addAutomaticKeepAlives: addAutomaticKeepAlives,
          addRepaintBoundaries: addRepaintBoundaries,
        ),
      );
    }

    return SuperSliverList.builder(
      itemCount: items.length + (hasMore ? 1 : 0),
      listController: listController,
      extentEstimation: extentEstimation,
      extentPrecalculationPolicy: extentPrecalculationPolicy,
      delayPopulatingCacheArea: delayPopulatingCacheArea,
      layoutKeptAliveChildren: layoutKeptAliveChildren,
      addAutomaticKeepAlives: addAutomaticKeepAlives,
      addRepaintBoundaries: addRepaintBoundaries,
      itemBuilder: builder,
    );
  }

  Widget _buildDefaultLoadingWidget() {
    return Column(
      children: List.generate(
        5,
        (index) => const Padding(
          padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          child: SkeletonLoader(height: 80),
        ),
      ),
    );
  }
}

/// Animated list with lightweight add/remove animations.
class OptimizedAnimatedList<T> extends ConsumerStatefulWidget {
  final List<T> items;
  final Widget Function(
    BuildContext context,
    T item,
    int index,
    Animation<double> animation,
  )
  itemBuilder;
  final Duration animationDuration;
  final Curve animationCurve;
  final EdgeInsetsGeometry? padding;
  final ScrollController? scrollController;
  final bool shrinkWrap;

  const OptimizedAnimatedList({
    super.key,
    required this.items,
    required this.itemBuilder,
    this.animationDuration = const Duration(milliseconds: 300),
    this.animationCurve = Curves.easeInOut,
    this.padding,
    this.scrollController,
    this.shrinkWrap = false,
  });

  @override
  ConsumerState<OptimizedAnimatedList<T>> createState() =>
      _OptimizedAnimatedListState<T>();
}

class _OptimizedAnimatedListState<T>
    extends ConsumerState<OptimizedAnimatedList<T>> {
  final GlobalKey<AnimatedListState> _listKey = GlobalKey<AnimatedListState>();
  late List<T> _items;

  @override
  void initState() {
    super.initState();
    _items = List.from(widget.items);
  }

  @override
  void didUpdateWidget(OptimizedAnimatedList<T> oldWidget) {
    super.didUpdateWidget(oldWidget);

    // Additions
    for (int i = 0; i < widget.items.length; i++) {
      if (i >= _items.length || widget.items[i] != _items[i]) {
        _items.insert(i, widget.items[i]);
        _listKey.currentState?.insertItem(
          i,
          duration: widget.animationDuration,
        );
      }
    }

    // Removals
    for (int i = _items.length - 1; i >= widget.items.length; i--) {
      final removedItem = _items[i];
      _items.removeAt(i);
      _listKey.currentState?.removeItem(
        i,
        (context, animation) =>
            widget.itemBuilder(context, removedItem, i, animation),
        duration: widget.animationDuration,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedList(
      key: _listKey,
      controller: widget.scrollController,
      padding: widget.padding,
      shrinkWrap: widget.shrinkWrap,
      initialItemCount: _items.length,
      itemBuilder: (context, index, animation) {
        if (index >= _items.length) return const SizedBox.shrink();
        return widget.itemBuilder(context, _items[index], index, animation);
      },
    );
  }
}
