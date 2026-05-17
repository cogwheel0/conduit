import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

PageRoute<T> buildPlatformPageRoute<T>({
  required WidgetBuilder builder,
  RouteSettings? settings,
  bool fullscreenDialog = false,
  bool opaque = true,
}) {
  switch (defaultTargetPlatform) {
    case TargetPlatform.iOS:
    case TargetPlatform.macOS:
      return SwipeablePageRoute<T>(
        builder: builder,
        settings: settings,
        fullscreenDialog: fullscreenDialog,
        opaque: opaque,
      );
    default:
      return MaterialPageRoute<T>(
        builder: builder,
        settings: settings,
        fullscreenDialog: fullscreenDialog,
      );
  }
}

class SwipeablePageRoute<T> extends PageRoute<T> {
  SwipeablePageRoute({
    required this.builder,
    super.settings,
    bool fullscreenDialog = false,
    bool opaque = true,
  }) : _fullscreenDialog = fullscreenDialog,
       _opaque = opaque;

  final WidgetBuilder builder;
  final bool _fullscreenDialog;
  final bool _opaque;

  @override
  bool get fullscreenDialog => _fullscreenDialog;

  @override
  bool get opaque => _opaque;

  @override
  Color? get barrierColor => null;

  @override
  String? get barrierLabel => null;

  @override
  bool get maintainState => true;

  @override
  Duration get transitionDuration => const Duration(milliseconds: 300);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return builder(context);
  }

  @override
  Widget buildTransitions(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    return const CupertinoPageTransitionsBuilder().buildTransitions<T>(
      this,
      context,
      animation,
      secondaryAnimation,
      child,
    );
  }
}
