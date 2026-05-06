import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
