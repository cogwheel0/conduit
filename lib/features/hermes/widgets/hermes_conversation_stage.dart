import 'package:material_ui/material_ui.dart';

import '../providers/hermes_mobile_navigation.dart';
import '../providers/hermes_mobile_route_stack.dart';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import '../../../platform/motion_probe.dart';
import '../../../shared/theme/theme_extensions.dart';

/// Same-shell shared identity. Logical navigation remains the shell's owner;
/// this owner retains only display geometry and the selected label.
class HermesConversationLink extends ChangeNotifier {
  final origins =
      <String, ({GlobalKey row, GlobalKey title, TextStyle? style})>{};
  final header = GlobalKey();
  String? id;
  String title = '';
  int? epoch;
  Rect? rowRect;
  Rect? titleRect;
  TextStyle? sourceStyle;
  TextStyle? headerStyle;
  bool pending = false;
  bool moving = false;
  bool _alive = true;
  void publish() {
    if (_alive) notifyListeners();
  }

  @override
  void dispose() {
    _alive = false;
    super.dispose();
  }

  static Rect? bounds(GlobalKey key) {
    final box = key.currentContext?.findRenderObject();
    if (box is! RenderBox || !box.attached || !box.hasSize) return null;
    return box.localToGlobal(Offset.zero) & box.size;
  }

  void begin(String selected, String label, int token) {
    final origin = origins[selected];
    id = selected;
    title = label;
    epoch = token;
    sourceStyle = origin?.style;
    rowRect = origin == null ? null : bounds(origin.row);
    titleRect = origin == null ? null : bounds(origin.title);
    pending = true;
    moving = false;
    notifyListeners();
    MotionProbe.mark('history-pending:$token');
  }

  void finish(int token, {required bool resolved}) {
    if (!_alive || epoch != token) return;
    pending = false;
    if (!resolved) {
      id = null;
      moving = false;
    }
    notifyListeners();
  }

  bool hides(String? selected) => moving && id == selected;
}

class HermesConversationLinkScope
    extends InheritedNotifier<HermesConversationLink> {
  const HermesConversationLinkScope({
    super.key,
    required HermesConversationLink link,
    required super.child,
  }) : super(notifier: link);
  static HermesConversationLink? of(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<HermesConversationLinkScope>()
      ?.notifier;
  static HermesConversationLink? read(BuildContext context) => context
      .getInheritedWidgetOfExactType<HermesConversationLinkScope>()
      ?.notifier;
}

class HermesConversationHeaderTitle extends StatelessWidget {
  const HermesConversationHeaderTitle({
    super.key,
    required this.id,
    required this.child,
  });
  final String? id;
  final Widget child;
  @override
  Widget build(BuildContext context) {
    final owner = HermesConversationLinkScope.of(context);
    if (owner == null) return child;
    owner.headerStyle = DefaultTextStyle.of(context).style
        .merge(child is Text ? (child as Text).style : null);
    return Opacity(
      key: owner.header,
      opacity: owner.hides(id) ? 0 : 1,
      alwaysIncludeSemantics: true,
      child: child,
    );
  }
}

/// Persistent list/detail hierarchy with a reversible, selected-row reveal.
/// No transcript shell is exposed while a fetch is unresolved.
class HermesConversationStage extends ConsumerStatefulWidget {
  const HermesConversationStage({
    super.key,
    required this.history,
    required this.detail,
    required this.logicalDetail,
    required this.chatArea,
    this.selectedId,
    this.other,
  });
  final Widget history;
  final Widget? detail;
  final bool logicalDetail;
  final bool chatArea;
  final String? selectedId;
  final Widget? other;
  @override
  ConsumerState<HermesConversationStage> createState() =>
      _HermesConversationStageState();
}

class _HermesConversationStageState
    extends ConsumerState<HermesConversationStage>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  static const experiment = bool.fromEnvironment(
    'CONDUIT_HISTORY_LINK',
    defaultValue: true,
  );
  final link = HermesConversationLink();
  final _stageKey = GlobalKey();
  late final _motion = AnimationController(vsync: this);
  Object? _service;
  bool _displayDetail = false;
  Rect? _source;
  Rect? _sourceTitle;
  Rect? _destinationTitle;
  int _transition = 0;
  bool _predictive = false;
  bool get _matchesSelection => link.id != null && link.id == widget.selectedId;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    link.addListener(_selectionChanged);
    _displayDetail = widget.logicalDetail;
    ref.listenManual(hermesSessionOpeningProvider, (_, next) {
      if (next == null && link.pending) {
        // Epoch invalidation is logical cancellation, not an exit animation.
        link.finish(link.epoch!, resolved: false);
      }
    });
  }

  void _selectionChanged() {
    if (link.pending && !widget.logicalDetail && _displayDetail) {
      _transition++;
      _motion.stop();
      setState(() => _displayDetail = false);
    }
  }

  @override
  void didUpdateWidget(covariant HermesConversationStage old) {
    super.didUpdateWidget(old);
    if (old.logicalDetail == widget.logicalDetail &&
        old.selectedId != widget.selectedId &&
        widget.logicalDetail &&
        !_matchesSelection) {
      _drop();
    }
    if (old.logicalDetail != widget.logicalDetail) {
      if (widget.logicalDetail) {
        _enter();
      } else if (widget.chatArea && _displayDetail) {
        _return();
      } else {
        _drop();
      }
    }
  }

  void _drop() {
    _transition++;
    _predictive = false;
    _motion.stop();
    _displayDetail = widget.logicalDetail;
    link.moving = false;
    link.pending = false;
    link.id = null;
    link.rowRect = null;
    link.titleRect = null;
  }

  void _enter() {
    _displayDetail = true;
    _source = link.rowRect;
    _sourceTitle = link.titleRect;
    _destinationTitle = null;
    if (!_matchesSelection ||
        !experiment ||
        context.reduceMotion ||
        _source == null ||
        _sourceTitle == null) {
      link.moving = false;
      _motion.value = 1;
      return;
    }
    link.moving = true;
    _motion.value = 0;
    final generation = ++_transition;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _transition || !widget.logicalDetail) {
        return;
      }
      _destinationTitle = HermesConversationLink.bounds(link.header);
      if (_destinationTitle == null) {
        setState(() => link.moving = false);
        return;
      }
      link.publish();
      MotionProbe.mark('history-enter');
      _motion.duration = context.motionDuration(
        AnimationDuration.conversationEnter,
      );
      _motion.forward().then((_) {
        if (!mounted || generation != _transition) return;
        setState(() => link.moving = false);
        link.publish();
        MotionProbe.mark('history-enter-end');
      });
    });
  }

  void _return() {
    final generation = ++_transition;
    // Logical Back already happened. Detail is inert and excluded from input,
    // focus and semantics while its existing pixels contract toward the row.
    if (!experiment || context.reduceMotion || !_matchesSelection) {
      _displayDetail = false;
      link.moving = false;
      return;
    }
    link.moving = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || generation != _transition || widget.logicalDetail) return;
      final origin = link.origins[link.id];
      final row = origin == null
          ? null
          : HermesConversationLink.bounds(origin.row);
      final title = origin == null
          ? null
          : HermesConversationLink.bounds(origin.title);
      final stage = HermesConversationLink.bounds(_stageKey);
      // A removed/offscreen row cannot be a truthful visual destination.
      if (row == null ||
          title == null ||
          stage == null ||
          !stage.overlaps(title)) {
        setState(() {
          _displayDetail = false;
          link.moving = false;
        });
        link.publish();
        MotionProbe.mark('history-return-no-origin');
        return;
      }
      _source = row;
      _sourceTitle = title;
      _destinationTitle ??= HermesConversationLink.bounds(link.header);
      link.publish();
      MotionProbe.mark('history-return');
      _motion.reverseDuration = context.motionDuration(
        AnimationDuration.conversationReturn,
      );
      _motion.reverse().then((_) {
        if (!mounted || generation != _transition) return;
        setState(() {
          _displayDetail = false;
          link.moving = false;
        });
        link.publish();
        MotionProbe.mark('history-return-end');
      });
    });
  }

  @override
  bool handleStartBackGesture(PredictiveBackEvent event) {
    if (!mounted ||
        !experiment ||
        context.reduceMotion ||
        !widget.logicalDetail ||
        !widget.chatArea ||
        link.moving ||
        !_matchesSelection ||
        ModalRoute.of(context)?.isCurrent == false ||
        ref.read(hermesMobileRouteStackProvider).hasPanels ||
        MediaQuery.viewInsetsOf(context).bottom > 0 ||
        ref.read(composerHasFocusProvider) ||
        ref.read(hermesMobileModelPanelProvider).hasActive) {
      return false;
    }
    final origin = link.origins[link.id];
    final row = origin == null
        ? null
        : HermesConversationLink.bounds(origin.row);
    final title = origin == null
        ? null
        : HermesConversationLink.bounds(origin.title);
    final stage = HermesConversationLink.bounds(_stageKey);
    if (row == null ||
        title == null ||
        stage == null ||
        !stage.overlaps(title)) {
      return false;
    }
    _source = row;
    _sourceTitle = title;
    _destinationTitle = HermesConversationLink.bounds(link.header);
    if (_destinationTitle == null) return false;
    _predictive = true;
    _transition++;
    setState(() => link.moving = true);
    link.publish();
    MotionProbe.mark('history-predictive-start');
    return true;
  }

  @override
  void handleUpdateBackGestureProgress(PredictiveBackEvent event) {
    if (!_predictive || !mounted) return;
    _motion.value = 1 - event.progress;
  }

  @override
  void handleCancelBackGesture() {
    if (!_predictive || !mounted) return;
    _predictive = false;
    final generation = ++_transition;
    _motion.duration = context.motionDuration(
      AnimationDuration.conversationEnter,
    );
    _motion.forward().then((_) {
      if (!mounted || generation != _transition) return;
      setState(() => link.moving = false);
      link.publish();
    });
    MotionProbe.mark('history-predictive-cancel');
  }

  @override
  void handleCommitBackGesture() {
    if (!_predictive || !mounted) return;
    _predictive = false;
    ref.read(hermesMobileNavigationProvider.notifier).back();
    MotionProbe.mark('history-predictive-commit');
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _motion.dispose();
    link.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(hermesApiServiceProvider);
    if (_service != null && !identical(service, _service)) _drop();
    _service = service;
    final moving = link.moving && experiment;
    final detailVisible =
        widget.chatArea && (_displayDetail || widget.logicalDetail);
    final historyVisible = widget.chatArea && (!widget.logicalDetail || moving);
    return HermesConversationLinkScope(
      link: link,
      child: AnimatedBuilder(
        animation: _motion,
        builder: (context, _) {
          final stage = HermesConversationLink.bounds(_stageKey);
          final offset = stage?.topLeft ?? Offset.zero;
          final full =
              Offset.zero & (stage?.size ?? MediaQuery.sizeOf(context));
          final t = Curves.easeInOutCubic.transform(_motion.value);
          final reveal = !moving || _source == null
              ? full
              : Rect.lerp(_source!.shift(-offset), full, t)!;
          final from = _sourceTitle?.shift(-offset);
          final to = _destinationTitle?.shift(-offset);
          final carrier = moving && from != null
              ? Rect.lerp(from, to ?? from, t)
              : null;
          // Theme text is resolved (inherit:false), while AppBar text can
          // inherit. Resolve both endpoints before interpolating the title.
          final baseStyle = DefaultTextStyle.of(context).style;
          return Stack(
            key: _stageKey,
            fit: StackFit.expand,
            children: [
              Offstage(
                offstage: !historyVisible,
                child: TickerMode(
                  enabled: historyVisible,
                  child: ExcludeFocus(
                    excluding: widget.logicalDetail,
                    child: IgnorePointer(
                      ignoring: widget.logicalDetail,
                      child: ExcludeSemantics(
                        excluding: widget.logicalDetail,
                        child: widget.history,
                      ),
                    ),
                  ),
                ),
              ),
              if (widget.detail != null)
                Offstage(
                  offstage: !detailVisible,
                  child: TickerMode(
                    enabled: widget.logicalDetail,
                    child: ExcludeFocus(
                      excluding: !widget.logicalDetail,
                      child: ExcludeSemantics(
                        excluding: !widget.logicalDetail,
                        child: IgnorePointer(
                          ignoring: !widget.logicalDetail || moving,
                          child: ClipPath(
                            clipper: _ConversationReveal(
                              reveal,
                              moving ? 12 * (1 - t) : 0,
                            ),
                            child: Stack(
                              fit: StackFit.expand,
                              children: [
                                ColoredBox(
                                  color: context.conduitTheme.surfaceBackground,
                                ),
                                // The title and resolved content share a moving
                                // header baseline. Text never crosses the title.
                                Opacity(
                                  opacity: moving && to == null ? 0 : 1,
                                  child: Transform.translate(
                                    offset: Offset(
                                      0,
                                      moving && carrier != null && to != null
                                          ? carrier.top - to.top
                                          : 0,
                                    ),
                                    child: RepaintBoundary(
                                      child: widget.detail!,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              if (widget.other != null) widget.other!,
              if (carrier != null)
                Positioned.fromRect(
                  rect: carrier,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: Text(
                        link.title,
                        key: ValueKey('conversation-carrier-${link.id}'),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle.lerp(
                          baseStyle
                              .merge(
                                link.sourceStyle ??
                                    Theme.of(context).textTheme.bodyLarge
                                        ?.copyWith(fontWeight: FontWeight.w500),
                              )
                              .copyWith(inherit: false),
                          baseStyle
                              .merge(
                                link.headerStyle ??
                                    Theme.of(
                                      context,
                                    ).textTheme.bodyLarge?.copyWith(
                                      fontSize: 16,
                                      fontWeight: FontWeight.w600,
                                      color: context.conduitTheme.textPrimary,
                                    ),
                              )
                              .copyWith(inherit: false),
                          t,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }
}

class _ConversationReveal extends CustomClipper<Path> {
  const _ConversationReveal(this.rect, this.radius);
  final Rect rect;
  final double radius;
  @override
  Path getClip(Size size) => Path()
    ..addRRect(
      RRect.fromRectAndRadius(
        rect.intersect(Offset.zero & size),
        Radius.circular(radius),
      ),
    );
  @override
  bool shouldReclip(_ConversationReveal old) =>
      old.rect != rect || old.radius != radius;
}
