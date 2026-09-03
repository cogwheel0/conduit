import 'dart:async';
import 'dart:math' as math;

import 'package:conduit/shared/widgets/platform_ui/platform_ui.dart';
import 'package:cupertino_ui/cupertino_ui.dart';
import 'package:flutter/foundation.dart' show listEquals, visibleForTesting;
import 'package:material_ui/material_ui.dart';
import 'package:flutter/rendering.dart'
    show
        MatrixUtils,
        RenderBox,
        RenderObject,
        ScrollCacheExtent,
        ScrollDirection;

import '../../../core/database/models/chat_transcript_window.dart';
import '../../../core/utils/debug_logger.dart';
import '../../../shared/widgets/measure_size.dart';

@visibleForTesting
const int debugChatTimelineInitialPositionMaxAttempts = 12;

@visibleForTesting
const double debugChatTimelineTrailingRefreshThreshold = 72;

const Duration _trailingRefreshTimeout = Duration(seconds: 20);

/// Builds the row at [sourceIndex] in the original [ChatTimelineViewport.messageIds].
///
/// The viewport defensively removes duplicate IDs for rendering and semantics,
/// but preserves this raw source index so callers keep their source-list
/// mapping.
typedef ChatTimelineRowBuilder = Widget Function(
  BuildContext context,
  int sourceIndex,
);

class _TimelineRowKey extends ValueKey<String> {
  const _TimelineRowKey(super.value);
}

/// Keeps an attached forward timeline on its trailing edge during layout.
///
/// A normal [ScrollController] learns about a growing sliver through a metrics
/// notification after the frame has painted. Correcting there leaves one frame
/// where the live footer moves down with the new assistant content. This
/// position performs the same correction while Flutter is resolving the new
/// content dimensions, before paint.
class _ChatTimelineScrollController extends ScrollController {
  _ChatTimelineScrollController({required this.shouldMaintainLatest});

  final bool Function() shouldMaintainLatest;

  @override
  ScrollPosition createScrollPosition(
    ScrollPhysics physics,
    ScrollContext context,
    ScrollPosition? oldPosition,
  ) {
    return _ChatTimelineScrollPosition(
      physics: physics,
      context: context,
      initialPixels: initialScrollOffset,
      keepScrollOffset: keepScrollOffset,
      oldPosition: oldPosition,
      debugLabel: debugLabel,
      shouldMaintainLatest: shouldMaintainLatest,
    );
  }
}

class _ChatTimelineScrollPosition extends ScrollPositionWithSingleContext {
  _ChatTimelineScrollPosition({
    required super.physics,
    required super.context,
    super.initialPixels,
    super.keepScrollOffset,
    super.oldPosition,
    super.debugLabel,
    required this.shouldMaintainLatest,
  });

  static const double _latestEpsilon = 0.5;

  final bool Function() shouldMaintainLatest;

  @override
  bool correctForNewDimensions(
    ScrollMetrics oldPosition,
    ScrollMetrics newPosition,
  ) {
    final wasAtLatest =
        (pixels - oldPosition.maxScrollExtent).abs() <= _latestEpsilon;
    if (shouldMaintainLatest() &&
        !isScrollingNotifier.value &&
        wasAtLatest &&
        (pixels - newPosition.maxScrollExtent).abs() > _latestEpsilon) {
      correctPixels(newPosition.maxScrollExtent);
      return false;
    }
    return super.correctForNewDimensions(oldPosition, newPosition);
  }
}

@immutable
class ChatTimelineViewportMetrics {
  const ChatTimelineViewportMetrics({
    required this.pixels,
    required this.minScrollExtent,
    required this.maxScrollExtent,
    required this.viewportDimension,
    required this.distanceFromLatest,
    required this.hasRealContentOverflow,
    required this.visibleMessageIds,
  });

  final double pixels;
  final double minScrollExtent;
  final double maxScrollExtent;
  final double viewportDimension;
  final double distanceFromLatest;
  final bool hasRealContentOverflow;
  final List<String> visibleMessageIds;

  bool get isAtLatest => distanceFromLatest <= 1;

  @override
  bool operator ==(Object other) {
    return identical(this, other) ||
        other is ChatTimelineViewportMetrics &&
            pixels == other.pixels &&
            minScrollExtent == other.minScrollExtent &&
            maxScrollExtent == other.maxScrollExtent &&
            viewportDimension == other.viewportDimension &&
            distanceFromLatest == other.distanceFromLatest &&
            hasRealContentOverflow == other.hasRealContentOverflow &&
            listEquals(visibleMessageIds, other.visibleMessageIds);
  }

  @override
  int get hashCode => Object.hash(
    pixels,
    minScrollExtent,
    maxScrollExtent,
    viewportDimension,
    distanceFromLatest,
    hasRealContentOverflow,
    Object.hashAll(visibleMessageIds),
  );
}

/// Pixel-precise command surface for [ChatTimelineViewport].
///
/// The controller deliberately exposes no item-position abstraction. Chat
/// rows can grow while streaming, so ownership and restoration are expressed
/// in real scroll pixels and measured row rectangles.
class ChatTimelineViewportController {
  _ChatTimelineViewportState? _state;
  bool _disposed = false;

  bool get isAttached => _state != null;
  bool get hasClients => _state?._scrollController.hasClients ?? false;
  bool get isProgrammaticNavigationActive =>
      _state?._programmaticNavigationActive ?? false;
  ChatTimelineViewportMetrics? get metrics => _state?._metricsSnapshot;

  double get distanceFromLatest => metrics?.distanceFromLatest ?? 0;
  bool get hasRealContentOverflow => metrics?.hasRealContentOverflow ?? false;
  List<String> get visibleMessageIds =>
      metrics?.visibleMessageIds ?? const <String>[];

  Rect? rowRect(String messageId) => _state?._rowRect(messageId);

  double? distanceFromMessageTop(String messageId) =>
      _state?._distanceFromMessageTop(messageId);

  bool anyOldestLoadedRowVisible() =>
      _state?._anyOldestLoadedRowVisible() ?? false;

  ChatScrollAnchor? captureTopVisibleAnchor({required int loadedCount}) =>
      _state?._captureTopVisibleAnchor(loadedCount: loadedCount);

  double? resolveLatestOffset() => _state?._resolveLatestOffset();

  void jumpToLatest() => _state?._jumpToLatest();

  void prepositionOneViewportFromLatest() =>
      _state?._prepositionOneViewportFromLatest();

  Future<void> animateToLatest({
    required Duration duration,
    required Curve curve,
  }) async {
    await _state?._animateToLatest(duration: duration, curve: curve);
  }

  Future<bool> jumpToOldest() async => await _state?._jumpToOldest() ?? false;

  Future<bool> animateToOldest({
    required Duration duration,
    required Curve curve,
  }) async {
    return await _state?._animateToOldest(duration: duration, curve: curve) ??
        false;
  }

  Future<bool> jumpMessageToTop(String messageId) async =>
      await _state?._jumpMessageToTop(messageId) ?? false;

  Future<bool> animateMessageToTop(
    String messageId, {
    required Duration duration,
    required Curve curve,
  }) async {
    return await _state?._moveMessageToTop(
          messageId,
          duration: duration,
          curve: curve,
        ) ??
        false;
  }

  void cancelProgrammaticNavigation() =>
      _state?._cancelProgrammaticNavigation();

  void requestLayoutMaintenance() => _state?._scheduleLayoutMaintenance();

  void dispose() {
    final state = _state;
    if (state != null && state.mounted) {
      DebugLogger.error(
        'timeline-controller-disposed-while-attached',
        scope: 'chat/timeline/viewport',
      );
    }
    state?._cancelProgrammaticNavigation();
    _state = null;
    _disposed = true;
  }

  void _attach(_ChatTimelineViewportState state) {
    if (_disposed) {
      assert(false, 'ChatTimelineViewportController reused after dispose.');
      DebugLogger.error(
        'timeline-controller-attach-after-dispose',
        scope: 'chat/timeline/viewport',
      );
      return;
    }
    _state = state;
  }

  void _detach(_ChatTimelineViewportState state) {
    if (identical(_state, state)) _state = null;
  }
}

class ChatTimelineViewport extends StatefulWidget {
  const ChatTimelineViewport({
    required this.controller,
    required this.ownerGeneration,
    required this.messageIds,
    required this.rowBuilder,
    required this.topContentInset,
    required this.bottomPadding,
    required this.scrollbarBottomInset,
    required this.horizontalPadding,
    required this.cacheExtent,
    required this.physics,
    required this.isLoadingOlder,
    required this.maintainVisibleAnchor,
    required this.followLatest,
    required this.pinAutomatic,
    required this.onPointerDown,
    required this.onUserDragStart,
    required this.onUserDragEnd,
    required this.onMetricsChanged,
    required this.onPinEndSpaceChanged,
    required this.onOldestThresholdReached,
    required this.onTrailingRefresh,
    required this.onNativeScrollToTop,
    this.initialAnchor,
    this.pinnedUserMessageId,
    this.liveFooter,
    this.trailingContent,
    this.hideUntilSettled = false,
    this.rowRebuildKeys = const <Object?>[],
    super.key,
  }) : assert(
         rowRebuildKeys.length == 0 ||
             rowRebuildKeys.length == messageIds.length,
         'Row rebuild keys must be empty or match the message count.',
       ),
       assert(
         !maintainVisibleAnchor || !followLatest,
         'Visible-anchor maintenance and latest-follow are exclusive.',
       );

  final ChatTimelineViewportController controller;
  final int ownerGeneration;
  final List<String> messageIds;
  final List<Object?> rowRebuildKeys;
  final ChatScrollAnchor? initialAnchor;
  final ChatTimelineRowBuilder rowBuilder;
  final String? pinnedUserMessageId;
  final Widget? liveFooter;
  final Widget? trailingContent;
  final double topContentInset;
  final double bottomPadding;
  final double scrollbarBottomInset;
  final double horizontalPadding;
  final double cacheExtent;
  final ScrollPhysics physics;
  final bool isLoadingOlder;
  final bool maintainVisibleAnchor;
  final bool followLatest;
  final bool pinAutomatic;
  final bool hideUntilSettled;
  final VoidCallback onPointerDown;
  final VoidCallback onUserDragStart;
  final VoidCallback onUserDragEnd;
  final ValueChanged<ChatTimelineViewportMetrics> onMetricsChanged;
  final ValueChanged<double> onPinEndSpaceChanged;
  final VoidCallback onOldestThresholdReached;
  final Future<void> Function() onTrailingRefresh;
  final Future<void> Function() onNativeScrollToTop;

  @override
  State<ChatTimelineViewport> createState() => _ChatTimelineViewportState();
}

class _VisibleAnchor {
  const _VisibleAnchor(this.messageId, this.offsetFromTopInset);

  final String messageId;
  final double offsetFromTopInset;
}

class _ChatTimelineViewportState extends State<ChatTimelineViewport>
    with WidgetsBindingObserver {
  static const double _geometryEpsilon = 0.5;
  static const double _refreshThreshold =
      debugChatTimelineTrailingRefreshThreshold;
  static const int _maxAnchorCorrectionAttempts = 8;
  static const int _minSeekAttempts = 12;
  static const int _maxSeekAttempts = 64;
  static const int _maxPinGeometryAttempts = 12;
  static const int _maxOldestSettleAttempts = 4;
  static const int _maxInitialPositionAttempts =
      debugChatTimelineInitialPositionMaxAttempts;
  static const int _oldestRowProbeCount = 3;
  static const Key _liveFooterSliverKey = ValueKey<String>(
    'chat-timeline-live-footer-sliver',
  );
  static const Key _trailingContentSliverKey = ValueKey<String>(
    'chat-timeline-trailing-content-sliver',
  );
  static const Key _pinSpacerSliverKey = ValueKey<String>(
    'chat-timeline-pin-spacer-sliver',
  );

  late final _ChatTimelineScrollController _scrollController;
  final GlobalKey _viewportKey = GlobalKey();
  final GlobalKey _centerSliverKey = GlobalKey();
  final GlobalKey _endSentinelKey = GlobalKey();
  final ValueNotifier<double> _pinSupportSpace = ValueNotifier<double>(0);
  final Map<String, GlobalKey> _rowKeys = <String, GlobalKey>{};
  final Map<String, int> _mountedRowCounts = <String, int>{};
  final Map<String, double> _rowExtents = <String, double>{};
  final Map<String, ({int sourceIndex, Object? rebuildKey, Widget widget})>
  _rowWidgetCache = {};
  Map<String, Rect>? _cachedFrameRowRects;
  int? _cachedRowRectFrameStamp;
  int _rowRectFrameStamp = 0;
  bool _rowRectSnapshotInvalidationScheduled = false;
  bool _geometryUnavailable = false;
  bool _geometryRecoveryCallbackScheduled = false;

  late List<({String id, int sourceIndex, Object? rebuildKey})>
  _timelineEntries;
  late List<String> _messageIds;
  late Set<String> _messageIdSet;
  late Map<String, int> _messageIndexById;
  late String _centerMessageId;
  late int _centerIndex;
  _VisibleAnchor? _freeAnchor;
  bool _centerRecoveryPending = false;
  ChatTimelineViewportMetrics? _metricsSnapshot;
  ChatTimelineViewportMetrics? _lastReportedMetrics;
  bool _userDragging = false;
  bool _programmaticNavigationActive = false;
  double? _seekEntryOffset;
  int? _seekEntryGeneration;
  bool _layoutMaintenanceScheduled = false;
  bool _metricsCallbackScheduled = false;
  bool _initialPositionResolved = false;
  bool _initialPositionCallbackScheduled = false;
  bool _initialEmptyFallbackVisible = false;
  bool _oldestThresholdVisible = false;
  bool _refreshTriggered = false;
  bool _refreshActive = false;
  bool _pinGeometryReported = false;
  double _pinEndSpace = 0;
  String? _cachedPinnedMessageId;
  double? _cachedPinnedTargetOffset;
  double _trailingOverscroll = 0;
  int _anchorCorrectionAttempts = 0;
  int _pinGeometryAttempts = 0;
  int _initialPositionAttempts = 0;
  int _initialPositionCallbackGeneration = 0;
  int _navigationGeneration = 0;
  int _refreshGeneration = 0;

  double get _effectivePinSupportSpace =>
      widget.pinnedUserMessageId == null ? 0 : _pinSupportSpace.value;

  bool get _maintainsLatestDuringLayout =>
      _initialPositionResolved &&
      widget.followLatest &&
      !widget.pinAutomatic &&
      !_centerRecoveryPending &&
      !_userDragging &&
      !_programmaticNavigationActive;

  @override
  void initState() {
    super.initState();
    _scrollController = _ChatTimelineScrollController(
      shouldMaintainLatest: () => mounted && _maintainsLatestDuringLayout,
    );
    WidgetsBinding.instance.addObserver(this);
    _syncTimelineEntries();
    _setCenterMessageId(_resolveInitialCenter());
    _syncRowKeys();
    widget.controller._attach(this);
    _scrollController.addListener(_handleControllerChanged);
    _scheduleInitialPositionCallback(_restoreInitialPosition);
  }

  @override
  void didUpdateWidget(covariant ChatTimelineViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previousMessageIds = _messageIds;
    final messageIdsChanged = !listEquals(
      oldWidget.messageIds,
      widget.messageIds,
    );
    final rowBuilderChanged = !identical(
      oldWidget.rowBuilder,
      widget.rowBuilder,
    );
    final entryConfigurationChanged =
        messageIdsChanged ||
        !identical(oldWidget.rowRebuildKeys, widget.rowRebuildKeys) ||
        rowBuilderChanged;
    if (rowBuilderChanged) _rowWidgetCache.clear();
    if ((oldWidget.maintainVisibleAnchor || widget.maintainVisibleAnchor) &&
        (_freeAnchor == null || _rowRect(_freeAnchor!.messageId) == null)) {
      // Capture before the new child configuration is laid out. This is the
      // exact screen coordinate that insertions and size changes must retain.
      final capturedAnchor = _captureVisibleMaintenanceAnchor();
      // A route transition can temporarily detach the row or insert an
      // unlaid-out transform above it. Keep the last valid anchor until a
      // complete render tree is measurable again.
      if (capturedAnchor != null) _freeAnchor = capturedAnchor;
    }
    if (entryConfigurationChanged) {
      _syncTimelineEntries();
    }
    if (messageIdsChanged) {
      _refreshCenterIndex();
    }
    if (!identical(oldWidget.controller, widget.controller)) {
      oldWidget.controller._detach(this);
      widget.controller._attach(this);
    }
    if (oldWidget.pinnedUserMessageId != widget.pinnedUserMessageId) {
      _pinGeometryReported = false;
      _pinGeometryAttempts = 0;
      _cachedPinnedMessageId = null;
      _cachedPinnedTargetOffset = null;
    }
    if (oldWidget.isLoadingOlder && !widget.isLoadingOlder) {
      _oldestThresholdVisible = false;
    }

    if (oldWidget.ownerGeneration != widget.ownerGeneration) {
      _handleOwnerGenerationChange();
    } else {
      _recoverCenterAfterIdChange(previousMessageIds);
    }

    if (messageIdsChanged) {
      _syncRowKeys();
      if (!_initialPositionResolved && _messageIds.isNotEmpty) {
        if (previousMessageIds.isEmpty) {
          // An asynchronously loaded transcript starts one bounded settlement
          // phase after the empty fallback. Layout-maintenance re-arms within
          // either phase never reset this monotonic retry budget.
          _initialPositionAttempts = 0;
        }
        _initialEmptyFallbackVisible = false;
        _scheduleInitialPositionCallback(_restoreInitialPosition);
      }
    }
    _scheduleLayoutMaintenance();
  }

  void _handleOwnerGenerationChange() {
    _cancelProgrammaticNavigation();
    _invalidateInitialPositionCallback();
    _setCenterMessageId(_resolveInitialCenter());
    _freeAnchor = null;
    _centerRecoveryPending = false;
    _metricsSnapshot = null;
    _lastReportedMetrics = null;
    _rowWidgetCache.clear();
    _rowExtents.clear();
    _anchorCorrectionAttempts = 0;
    _initialPositionResolved = false;
    _initialEmptyFallbackVisible = false;
    _oldestThresholdVisible = false;
    _initialPositionAttempts = 0;
    _pinEndSpace = 0;
    _pinSupportSpace.value = 0;
    _pinGeometryReported = false;
    _pinGeometryAttempts = 0;
    _cachedPinnedMessageId = null;
    _cachedPinnedTargetOffset = null;
    _resetRefreshGesture();
    _scheduleInitialPositionCallback(_restoreInitialPosition);
  }

  void _recoverCenterAfterIdChange(List<String> previousMessageIds) {
    if (_messageIdSet.contains(_centerMessageId)) return;
    final rowRects = _mountedRowRectSnapshot();
    final topVisibleAnchor = _captureVisibleMaintenanceAnchor(rowRects);
    final previouslyVisibleIds = _visibleMessageIds(
      previousMessageIds,
      rowRects,
    );
    final survivingAnchor = _freeAnchor?.messageId;
    String? survivingVisible;
    for (final id in previouslyVisibleIds) {
      if (_messageIdSet.contains(id)) {
        survivingVisible = id;
        break;
      }
    }
    final survivingBoundary = _nearestSurvivingCenter(
      previousMessageIds,
      _messageIdSet,
    );
    final centerRecoveryAnchor =
        topVisibleAnchor != null &&
            _messageIdSet.contains(topVisibleAnchor.messageId)
        ? topVisibleAnchor
        : survivingVisible == null
        ? null
        : _captureVisibleMaintenanceAnchorForMessage(survivingVisible);
    _setCenterMessageId(
      survivingBoundary ??
          (survivingAnchor != null && _messageIdSet.contains(survivingAnchor)
              ? survivingAnchor
              : survivingVisible ?? _resolveInitialCenter()),
    );
    if (centerRecoveryAnchor != null) {
      _freeAnchor = centerRecoveryAnchor;
      _centerRecoveryPending = true;
      _anchorCorrectionAttempts = 0;
    } else if (!widget.maintainVisibleAnchor ||
        survivingAnchor == null ||
        !_messageIdSet.contains(survivingAnchor)) {
      _freeAnchor = null;
      _centerRecoveryPending = false;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller._detach(this);
    _metricsSnapshot = null;
    _lastReportedMetrics = null;
    _scrollController
      ..removeListener(_handleControllerChanged)
      ..dispose();
    _pinSupportSpace.dispose();
    super.dispose();
  }

  @override
  void handleStatusBarTap() {
    super.handleStatusBarTap();
    if (!mounted ||
        !_scrollController.hasClients ||
        !TickerMode.valuesOf(context).enabled) {
      return;
    }
    final route = ModalRoute.of(context);
    if (route != null && !route.isCurrent) return;
    unawaited(
      Future<void>.sync(widget.onNativeScrollToTop)
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              'native-scroll-to-top-failed',
              scope: 'chat/timeline/viewport',
              error: error,
              stackTrace: stackTrace,
            );
          }),
    );
  }

  String _resolveInitialCenter() {
    if (_messageIds.isEmpty) return '';
    final savedId = widget.initialAnchor?.messageId;
    if (savedId != null && _messageIdSet.contains(savedId)) {
      return savedId;
    }
    // The fixed center is deliberately the oldest row in the initial window.
    // Newer rows remain chronological in the forward center sliver while
    // older pages grow into negative extents without moving visible content.
    return _messageIds.first;
  }

  String? _nearestSurvivingCenter(
    List<String> previousIds,
    Set<String> nextIds,
  ) {
    final previousIndex = previousIds.indexOf(_centerMessageId);
    if (previousIndex < 0 || nextIds.isEmpty) return null;
    for (var distance = 1; distance < previousIds.length; distance += 1) {
      final newerIndex = previousIndex + distance;
      if (newerIndex < previousIds.length &&
          nextIds.contains(previousIds[newerIndex])) {
        return previousIds[newerIndex];
      }
      final olderIndex = previousIndex - distance;
      if (olderIndex >= 0 && nextIds.contains(previousIds[olderIndex])) {
        return previousIds[olderIndex];
      }
    }
    return null;
  }

  void _syncTimelineEntries() {
    final seen = <String>{};
    final entries = <({String id, int sourceIndex, Object? rebuildKey})>[];
    for (var index = 0; index < widget.messageIds.length; index += 1) {
      final id = widget.messageIds[index];
      if (seen.add(id)) {
        entries.add((
          id: id,
          sourceIndex: index,
          rebuildKey: widget.rowRebuildKeys.isEmpty
              ? widget.rowBuilder
              : widget.rowRebuildKeys[index],
        ));
      }
    }
    _timelineEntries = List.unmodifiable(entries);
    _messageIds = List.unmodifiable(entries.map((entry) => entry.id));
    _messageIdSet = Set.unmodifiable(seen);
    _messageIndexById = Map.unmodifiable({
      for (var index = 0; index < entries.length; index += 1)
        entries[index].id: index,
    });
    _rowWidgetCache.removeWhere((id, _) => !seen.contains(id));
    _rowExtents.removeWhere((id, _) => !seen.contains(id));
  }

  void _syncRowKeys() {
    _rowKeys.removeWhere((id, _) => !_messageIdSet.contains(id));
    for (final id in _messageIds) {
      _rowKeys.putIfAbsent(id, GlobalKey.new);
    }
  }

  void _setCenterMessageId(String messageId) {
    _centerMessageId = messageId;
    _refreshCenterIndex();
  }

  void _refreshCenterIndex() {
    _centerIndex = _messageIndexById[_centerMessageId] ?? 0;
  }

  RenderBox? _renderBoxFor(GlobalKey key) {
    final renderObject = key.currentContext?.findRenderObject();
    return renderObject is RenderBox && renderObject.hasSize
        ? renderObject
        : null;
  }

  Rect? _globalRectFor(GlobalKey key) {
    final box = _renderBoxFor(key);
    if (box == null || !_hasUsableGlobalTransform(box)) return null;
    final topLeft = box.localToGlobal(Offset.zero);
    if (!topLeft.isFinite) return null;
    final rect = topLeft & box.size;
    return rect.isFinite ? rect : null;
  }

  bool _hasUsableGlobalTransform(RenderBox box) {
    final owner = box.owner;
    if (!box.attached || owner == null || owner.rootNode == null) return false;

    RenderObject? current = box;
    while (current != null) {
      if (!current.attached || !identical(current.owner, owner)) return false;
      if (current is RenderBox && !current.hasSize) return false;
      if (identical(current, owner.rootNode)) return true;
      final parent = current.parent;
      if (parent is! RenderObject) return false;
      current = parent;
    }
    return false;
  }

  bool _hasUsableViewportGeometry() {
    if (_viewportRect != null) return true;
    _geometryUnavailable = true;
    _scheduleGeometryRecoveryCallback();
    return false;
  }

  void _scheduleGeometryRecoveryCallback() {
    if (_geometryRecoveryCallbackScheduled) return;
    _geometryRecoveryCallbackScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _geometryRecoveryCallbackScheduled = false;
      if (!mounted || !_geometryUnavailable) return;
      if (_viewportRect == null) {
        // Observe the next naturally scheduled frame without forcing frames
        // while this state is detached or covered by another route.
        _scheduleGeometryRecoveryCallback();
        return;
      }
      _geometryUnavailable = false;
      _scheduleMetricsCallback();
      _scheduleLayoutMaintenance();
    });
  }

  // Deliberately uncached: anchor settlement and pin seeks measure across
  // intra-frame jumpTo corrections, where a per-frame snapshot would serve a
  // pre-jump rect and double-apply corrections.
  Rect? _rowRect(String messageId) {
    final key = _rowKeys[messageId];
    return key == null ? null : _globalRectFor(key);
  }

  Map<String, Rect> _mountedRowRectSnapshot() {
    final viewport = _renderBoxFor(_viewportKey);
    final viewportRect = _viewportRect;
    if (viewport == null || viewportRect == null) {
      return const <String, Rect>{};
    }
    final viewportToGlobal = viewport.getTransformTo(null);
    final rects = <String, Rect>{};
    for (final id in _mountedRowCounts.keys) {
      final key = _rowKeys[id];
      if (key == null || key.currentContext == null) continue;
      final box = _renderBoxFor(key);
      if (box == null || !identical(box.owner, viewport.owner)) continue;
      final transform = viewportToGlobal.clone()
        ..multiply(box.getTransformTo(viewport));
      final rect = MatrixUtils.transformRect(transform, Offset.zero & box.size);
      if (rect.isFinite) rects[id] = rect;
    }
    return Map<String, Rect>.unmodifiable(rects);
  }

  Map<String, Rect> _frameRowRectSnapshot() {
    final cached = _cachedFrameRowRects;
    if (cached != null && _cachedRowRectFrameStamp == _rowRectFrameStamp) {
      return cached;
    }
    final snapshot = _mountedRowRectSnapshot();
    _cachedFrameRowRects = snapshot;
    _cachedRowRectFrameStamp = _rowRectFrameStamp;
    if (!_rowRectSnapshotInvalidationScheduled) {
      _rowRectSnapshotInvalidationScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _rowRectFrameStamp += 1;
        _rowRectSnapshotInvalidationScheduled = false;
        _cachedFrameRowRects = null;
        _cachedRowRectFrameStamp = null;
      });
    }
    return snapshot;
  }

  Rect? get _viewportRect => _globalRectFor(_viewportKey);

  List<String> _visibleMessageIds([
    Iterable<String>? candidateIds,
    Map<String, Rect>? rowRects,
  ]) {
    final viewport = _viewportRect;
    if (viewport == null) return const <String>[];
    final top = viewport.top + widget.topContentInset;
    final bottom = viewport.bottom;
    final candidates = candidateIds?.toSet();
    final visible = <({String id, double top})>[];
    for (final entry in (rowRects ?? _mountedRowRectSnapshot()).entries) {
      final id = entry.key;
      if (candidates != null && !candidates.contains(id)) {
        continue;
      }
      final rect = entry.value;
      if (rect.bottom <= top || rect.top >= bottom) continue;
      visible.add((id: id, top: rect.top));
    }
    visible.sort((left, right) => left.top.compareTo(right.top));
    return List<String>.unmodifiable(visible.map((entry) => entry.id));
  }

  bool _anyOldestLoadedRowVisible([Map<String, Rect>? rowRects]) {
    final viewport = _viewportRect;
    if (viewport == null) return false;
    final top = viewport.top + widget.topContentInset;
    final bottom = viewport.bottom;
    final rects = rowRects ?? _mountedRowRectSnapshot();
    for (final id in _messageIds.take(_oldestRowProbeCount)) {
      final rect = rects[id];
      if (rect != null && rect.bottom > top && rect.top < bottom) return true;
    }
    return false;
  }

  ({String id, Rect rect})? _topVisibleRow([Map<String, Rect>? rowRects]) {
    final viewport = _viewportRect;
    if (viewport == null) return null;
    final insetY = viewport.top + widget.topContentInset;
    ({String id, Rect rect})? intersecting;
    ({String id, Rect rect})? nearestBelow;
    for (final entry in (rowRects ?? _mountedRowRectSnapshot()).entries) {
      final id = entry.key;
      final rect = entry.value;
      if (rect.bottom <= insetY) continue;
      if (rect.top <= insetY) {
        if (intersecting == null || rect.top > intersecting.rect.top) {
          intersecting = (id: id, rect: rect);
        }
      } else if (nearestBelow == null || rect.top < nearestBelow.rect.top) {
        nearestBelow = (id: id, rect: rect);
      }
    }
    return intersecting ?? nearestBelow;
  }

  ChatScrollAnchor? _captureTopVisibleAnchor({required int loadedCount}) {
    final viewport = _viewportRect;
    if (viewport == null) return null;
    final insetY = viewport.top + widget.topContentInset;
    final best = _topVisibleRow();
    if (best == null) return null;
    return ChatScrollAnchor(
      messageId: best.id,
      offsetWithinMessage: best.rect.top - insetY,
      loadedCount: loadedCount,
    );
  }

  _VisibleAnchor? _captureVisibleMaintenanceAnchor([
    Map<String, Rect>? rowRects,
  ]) {
    final row = _topVisibleRow(rowRects);
    final viewport = _viewportRect;
    if (row == null || viewport == null) return null;
    return _VisibleAnchor(
      row.id,
      row.rect.top - (viewport.top + widget.topContentInset),
    );
  }

  _VisibleAnchor? _captureVisibleMaintenanceAnchorForMessage(String messageId) {
    final rect = _rowRect(messageId);
    final viewport = _viewportRect;
    if (rect == null || viewport == null) return null;
    return _VisibleAnchor(
      messageId,
      rect.top - (viewport.top + widget.topContentInset),
    );
  }

  ScrollPosition? get _dimensionedPosition {
    if (!_scrollController.hasClients) return null;
    final position = _scrollController.position;
    return position.hasContentDimensions ? position : null;
  }

  double? _resolveLatestOffset() {
    final position = _dimensionedPosition;
    return position == null ? null : _contentLatestOffset(position);
  }

  double _contentLatestOffset(ScrollPosition position) {
    return (position.maxScrollExtent - _effectivePinSupportSpace)
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
  }

  double? _distanceFromMessageTop(String messageId) {
    final position = _dimensionedPosition;
    if (position == null) return null;
    final measuredTarget = _targetOffsetForMessageTop(messageId);
    if (measuredTarget != null) {
      _cachedPinnedMessageId = messageId;
      _cachedPinnedTargetOffset = measuredTarget;
    }
    final target =
        measuredTarget ??
        (_cachedPinnedMessageId == messageId
            ? _cachedPinnedTargetOffset
            : null);
    return target == null ? null : (target - position.pixels).abs();
  }

  ChatTimelineViewportMetrics? _currentMetrics([Map<String, Rect>? rowRects]) {
    if (!_scrollController.hasClients) return null;
    return _metricsForCurrentPosition(
      visibleMessageIds: _visibleMessageIds(null, rowRects),
    );
  }

  ChatTimelineViewportMetrics? _metricsForCurrentPosition({
    required List<String> visibleMessageIds,
  }) {
    final position = _dimensionedPosition;
    if (position == null) return null;
    final latest = _contentLatestOffset(position);
    final distance = math.max(0, latest - position.pixels).toDouble();
    final realOverflow =
        (position.maxScrollExtent - position.minScrollExtent) -
            _effectivePinSupportSpace -
            widget.bottomPadding >
        _geometryEpsilon;
    return ChatTimelineViewportMetrics(
      pixels: position.pixels,
      minScrollExtent: position.minScrollExtent,
      maxScrollExtent: position.maxScrollExtent,
      viewportDimension: position.viewportDimension,
      distanceFromLatest: distance,
      hasRealContentOverflow: realOverflow,
      visibleMessageIds: visibleMessageIds,
    );
  }

  void _handleControllerChanged() {
    // Visible IDs are intentionally carried from the last completed frame.
    // Per-tick consumers use only these lightweight pixel/extent values; the
    // scheduled callback refreshes row geometry exactly once per frame.
    final previous = _metricsSnapshot;
    final position = _dimensionedPosition;
    if (position == null) return;
    if (previous != null &&
        previous.pixels == position.pixels &&
        previous.minScrollExtent == position.minScrollExtent &&
        previous.maxScrollExtent == position.maxScrollExtent &&
        previous.viewportDimension == position.viewportDimension) {
      return;
    }
    _metricsSnapshot =
        _metricsForCurrentPosition(
          visibleMessageIds: previous?.visibleMessageIds ?? const <String>[],
        ) ??
        previous;
    _scheduleMetricsCallback();
  }

  void _scheduleMetricsCallback() {
    if (_metricsCallbackScheduled) return;
    _metricsCallbackScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _metricsCallbackScheduled = false;
      if (!mounted) return;
      if (!_hasUsableViewportGeometry()) return;
      final metrics = _currentMetrics(_frameRowRectSnapshot());
      if (metrics == null) return;
      _metricsSnapshot = metrics;
      if (metrics == _lastReportedMetrics) return;
      _lastReportedMetrics = metrics;
      widget.onMetricsChanged(metrics);
    });
    binding.scheduleFrame();
  }

  void _scheduleLayoutMaintenance() {
    if (_layoutMaintenanceScheduled) return;
    _layoutMaintenanceScheduled = true;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      _layoutMaintenanceScheduled = false;
      if (!mounted || !_scrollController.hasClients) return;
      // A route transition can leave this mounted state between render trees.
      // Do not turn that transient measurement outage into empty geometry.
      if (!_hasUsableViewportGeometry()) return;
      if (!_initialPositionResolved && _messageIds.isNotEmpty) {
        // Re-arm asynchronous transcript settlement even when the parent
        // republishes an identity-equal message-ID list after the empty or
        // unattached fallback exhausted its bounded frame polling.
        _scheduleInitialPositionCallback(_restoreInitialPosition);
      }
      final rowRects = _frameRowRectSnapshot();
      final centerRecoveryOwnedFrame = _maintainVisibleContent(rowRects);
      _updatePinGeometry();
      final oldestThresholdVisible = _anyOldestLoadedRowVisible(rowRects);
      if (!oldestThresholdVisible) {
        _oldestThresholdVisible = false;
      } else if (!widget.isLoadingOlder && !_oldestThresholdVisible) {
        _oldestThresholdVisible = true;
        widget.onOldestThresholdReached();
      }
      if (!centerRecoveryOwnedFrame &&
          widget.followLatest &&
          !widget.pinAutomatic &&
          !_userDragging &&
          !_programmaticNavigationActive &&
          !(_dimensionedPosition?.isScrollingNotifier.value ?? false)) {
        final position = _dimensionedPosition;
        if (position != null &&
            (_contentLatestOffset(position) - position.pixels).abs() >
                _geometryEpsilon) {
          _jumpToLatest();
        }
      }
      _scheduleMetricsCallback();
    });
    binding.scheduleFrame();
  }

  bool _maintainVisibleContent(Map<String, Rect> rowRects) {
    final centerRecoveryOwnedFrame = _centerRecoveryPending;
    if ((!widget.maintainVisibleAnchor && !centerRecoveryOwnedFrame) ||
        _userDragging ||
        _programmaticNavigationActive) {
      return _releaseVisibleAnchorOwnership(
        centerRecoveryOwnedFrame: centerRecoveryOwnedFrame,
        rowRects: rowRects,
      );
    }
    final anchor = _freeAnchor;
    if (anchor == null) {
      return _releaseVisibleAnchorOwnership(
        centerRecoveryOwnedFrame: centerRecoveryOwnedFrame,
        rowRects: rowRects,
      );
    }
    final current = rowRects[anchor.messageId];
    final viewport = _viewportRect;
    if (current == null || viewport == null) {
      if (centerRecoveryOwnedFrame &&
          _anchorCorrectionAttempts < _maxAnchorCorrectionAttempts) {
        _anchorCorrectionAttempts += 1;
        _scheduleLayoutMaintenance();
        return true;
      }
      return _releaseVisibleAnchorOwnership(
        centerRecoveryOwnedFrame: centerRecoveryOwnedFrame,
        rowRects: rowRects,
      );
    }
    final currentOffset = current.top - (viewport.top + widget.topContentInset);
    final delta = currentOffset - anchor.offsetFromTopInset;
    final position = _dimensionedPosition;
    if (delta.abs() > _geometryEpsilon && position != null) {
      if (position.isScrollingNotifier.value) {
        // Ballistic activity can outlive the pointer drag. Treat it as user
        // ownership and adopt the moving viewport instead of fighting its
        // momentum with an anchor correction.
        _anchorCorrectionAttempts = 0;
        _centerRecoveryPending = false;
        _freeAnchor = _captureVisibleMaintenanceAnchor(rowRects);
        return centerRecoveryOwnedFrame;
      }
      final target = (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((target - position.pixels).abs() > _geometryEpsilon) {
        if (_anchorCorrectionAttempts >= _maxAnchorCorrectionAttempts) {
          return _releaseVisibleAnchorOwnership(
            centerRecoveryOwnedFrame: centerRecoveryOwnedFrame,
            rowRects: rowRects,
          );
        }
        _anchorCorrectionAttempts += 1;
        position.jumpTo(target);
        // The old row geometry remains visible until the corrective jump lays
        // out. Retain the anchor and capture its settled coordinate next frame.
        _scheduleLayoutMaintenance();
        return centerRecoveryOwnedFrame;
      }
    }
    return _releaseVisibleAnchorOwnership(
      centerRecoveryOwnedFrame: centerRecoveryOwnedFrame,
      rowRects: rowRects,
    );
  }

  bool _releaseVisibleAnchorOwnership({
    required bool centerRecoveryOwnedFrame,
    required Map<String, Rect> rowRects,
  }) {
    _anchorCorrectionAttempts = 0;
    _centerRecoveryPending = false;
    _freeAnchor = widget.maintainVisibleAnchor
        ? _captureVisibleMaintenanceAnchor(rowRects)
        : null;
    return centerRecoveryOwnedFrame;
  }

  void _updatePinGeometry() {
    final pinnedId = widget.pinnedUserMessageId;
    if (pinnedId == null) {
      _pinGeometryAttempts = 0;
      _cachedPinnedMessageId = null;
      _cachedPinnedTargetOffset = null;
      _pinEndSpace = 0;
      if (_pinSupportSpace.value != 0) _pinSupportSpace.value = 0;
      if (!_pinGeometryReported) {
        _pinGeometryReported = true;
        widget.onPinEndSpaceChanged(0);
      }
      return;
    }
    // Mid-scroll the pin's fixed pixel target and viewport-sized support
    // cannot change; once geometry has been reported, skip the global
    // measurements until the motion settles (drag end re-runs maintenance).
    if (_pinGeometryReported &&
        _scrollController.hasClients &&
        _scrollController.position.isScrollingNotifier.value) {
      return;
    }
    final viewport = _viewportRect;
    final pinned = _rowRect(pinnedId);
    final sentinel = _globalRectFor(_endSentinelKey);
    if (viewport == null || pinned == null || sentinel == null) {
      if (_pinGeometryAttempts < _maxPinGeometryAttempts) {
        _pinGeometryAttempts += 1;
        _scheduleLayoutMaintenance();
      } else if (!_pinGeometryReported) {
        _pinGeometryReported = true;
        widget.onPinEndSpaceChanged(_pinEndSpace);
      }
      return;
    }
    _pinGeometryAttempts = 0;
    if ((viewport.height - _pinSupportSpace.value).abs() > _geometryEpsilon) {
      _pinSupportSpace.value = viewport.height;
    }
    final pinnedTarget = _targetOffsetForMessageTop(pinnedId);
    if (pinnedTarget != null) {
      _cachedPinnedMessageId = pinnedId;
      _cachedPinnedTargetOffset = pinnedTarget;
    }
    final activeTurnExtent = math.max(0, sentinel.top - pinned.top).toDouble();
    final next = math
        .max(
          0,
          viewport.height -
              widget.topContentInset -
              activeTurnExtent -
              widget.bottomPadding,
        )
        .toDouble();
    final changed = (next - _pinEndSpace).abs() > _geometryEpsilon;
    if (changed) _pinEndSpace = next;
    if (!changed && _pinGeometryReported) return;
    _pinGeometryReported = true;
    widget.onPinEndSpaceChanged(next);
  }

  void _restoreInitialPosition() {
    final ownerGeneration = widget.ownerGeneration;
    final saved = widget.initialAnchor;
    if (_messageIds.isEmpty) {
      // The transcript can arrive asynchronously, with or without a saved
      // anchor. Keep settlement unresolved so a later message-list update can
      // restore the anchor or settle authoritatively at latest.
      if (_initialPositionAttempts >= _maxInitialPositionAttempts) {
        // Stop frame polling without marking restoration complete. A later
        // non-empty message-list update re-arms exact anchor restoration.
        if (!_initialEmptyFallbackVisible) {
          setState(() => _initialEmptyFallbackVisible = true);
        }
        return;
      }
      _initialPositionAttempts += 1;
      _scheduleInitialPositionCallback(_restoreInitialPosition);
      return;
    }
    if (!_scrollController.hasClients) {
      if (_initialPositionAttempts >= _maxInitialPositionAttempts) {
        _finishInitialPosition(ownerGeneration);
        return;
      }
      _initialPositionAttempts += 1;
      _scheduleInitialPositionCallback(_restoreInitialPosition);
      return;
    }
    _updatePinGeometry();
    if (saved != null && _messageIdSet.contains(saved.messageId)) {
      _settleInitialSavedAnchor(saved, ownerGeneration);
      return;
    }
    _settleInitialLatestPosition(ownerGeneration);
  }

  bool _ownsInitialPosition(int ownerGeneration) {
    return mounted &&
        !_initialPositionResolved &&
        widget.ownerGeneration == ownerGeneration;
  }

  void _scheduleInitialPositionCallback(VoidCallback callback) {
    if (_initialPositionResolved || _initialPositionCallbackScheduled) return;
    _initialPositionCallbackScheduled = true;
    final callbackGeneration = ++_initialPositionCallbackGeneration;
    final ownerGeneration = widget.ownerGeneration;
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!mounted ||
          callbackGeneration != _initialPositionCallbackGeneration) {
        return;
      }
      _initialPositionCallbackScheduled = false;
      if (_ownsInitialPosition(ownerGeneration)) callback();
    });
    binding.scheduleFrame();
  }

  void _invalidateInitialPositionCallback() {
    _initialPositionCallbackGeneration += 1;
    _initialPositionCallbackScheduled = false;
  }

  void _settleInitialSavedAnchor(ChatScrollAnchor saved, int ownerGeneration) {
    if (!_ownsInitialPosition(ownerGeneration) ||
        !_scrollController.hasClients) {
      return;
    }
    final rect = _rowRect(saved.messageId);
    final viewport = _viewportRect;
    if (rect == null || viewport == null) {
      _settleInitialLatestPosition(ownerGeneration);
      return;
    }
    final desired =
        viewport.top + widget.topContentInset + saved.offsetWithinMessage;
    final delta = rect.top - desired;
    if (delta.abs() <= _geometryEpsilon ||
        _initialPositionAttempts >= _maxInitialPositionAttempts) {
      _finishInitialPosition(ownerGeneration);
      return;
    }
    final position = _dimensionedPosition;
    if (position == null) {
      if (_initialPositionAttempts >= _maxInitialPositionAttempts) {
        _finishInitialPosition(ownerGeneration);
        return;
      }
      _initialPositionAttempts += 1;
      _scheduleInitialPositionCallback(
        () => _settleInitialSavedAnchor(saved, ownerGeneration),
      );
      return;
    }
    position.jumpTo(
      (position.pixels + delta)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble(),
    );
    _initialPositionAttempts += 1;
    _scheduleInitialPositionCallback(
      () => _settleInitialSavedAnchor(saved, ownerGeneration),
    );
  }

  void _settleInitialLatestPosition(int ownerGeneration) {
    if (!_ownsInitialPosition(ownerGeneration) ||
        !_scrollController.hasClients) {
      return;
    }
    final position = _dimensionedPosition;
    if (position == null) {
      if (_initialPositionAttempts >= _maxInitialPositionAttempts) {
        _finishInitialPosition(ownerGeneration);
        return;
      }
      _initialPositionAttempts += 1;
      _scheduleInitialPositionCallback(
        () => _settleInitialLatestPosition(ownerGeneration),
      );
      return;
    }
    _freeAnchor = null;
    position.jumpTo(_contentLatestOffset(position));
    _scheduleInitialPositionCallback(() {
      if (!_ownsInitialPosition(ownerGeneration) ||
          !_scrollController.hasClients) {
        return;
      }
      final position = _dimensionedPosition;
      if (position == null) {
        _settleInitialLatestPosition(ownerGeneration);
        return;
      }
      final sentinelReady = _renderBoxFor(_endSentinelKey) != null;
      final atLatest =
          (_contentLatestOffset(position) - position.pixels).abs() <=
          _geometryEpsilon;
      if ((!sentinelReady || !atLatest) &&
          _initialPositionAttempts < _maxInitialPositionAttempts) {
        _initialPositionAttempts += 1;
        _settleInitialLatestPosition(ownerGeneration);
        return;
      }
      _finishInitialPosition(ownerGeneration);
    });
  }

  void _finishInitialPosition(int ownerGeneration) {
    if (!_ownsInitialPosition(ownerGeneration)) return;
    _invalidateInitialPositionCallback();
    _freeAnchor = _captureVisibleMaintenanceAnchor();
    setState(() {
      _initialPositionResolved = true;
      _initialEmptyFallbackVisible = false;
    });
    _scheduleMetricsCallback();
  }

  void _jumpToLatest() {
    final position = _dimensionedPosition;
    if (position == null) return;
    _freeAnchor = null;
    position.jumpTo(_contentLatestOffset(position));
  }

  void _prepositionOneViewportFromLatest() {
    if (_dimensionedPosition == null) return;
    _cancelProgrammaticNavigation();
    final generation = _navigationGeneration;
    _freeAnchor = null;
    void applyBoundedPosition() {
      final position = _dimensionedPosition;
      if (position == null) return;
      final latest = _contentLatestOffset(position);
      position.jumpTo(
        math.max(position.minScrollExtent, latest - position.viewportDimension),
      );
    }

    applyBoundedPosition();
    // A lazy sliver can refine maxScrollExtent after the jump builds its next
    // viewport of children. Re-apply once after layout so the visible staging
    // point never ends farther than one viewport from the real target.
    final binding = WidgetsBinding.instance;
    binding.addPostFrameCallback((_) {
      if (!mounted ||
          _userDragging ||
          generation != _navigationGeneration ||
          _programmaticNavigationActive) {
        return;
      }
      applyBoundedPosition();
    });
    binding.scheduleFrame();
  }

  Future<void> _animateToLatest({
    required Duration duration,
    required Curve curve,
  }) async {
    var position = _dimensionedPosition;
    if (position == null) return;
    if (_programmaticNavigationActive) {
      _cancelProgrammaticNavigation();
    }
    final generation = ++_navigationGeneration;
    _programmaticNavigationActive = true;
    try {
      var target = _contentLatestOffset(position);
      final distance = (target - position.pixels).abs();
      if (distance > position.viewportDimension) {
        position.jumpTo(
          math.max(
            position.minScrollExtent,
            target - position.viewportDimension,
          ),
        );
        await WidgetsBinding.instance.endOfFrame;
        if (!mounted || generation != _navigationGeneration) {
          return;
        }
        position = _dimensionedPosition;
        if (position == null) return;
        target = _contentLatestOffset(position);
      }
      await _scrollController.animateTo(
        target,
        duration: duration,
        curve: curve,
      );
    } finally {
      if (mounted && generation == _navigationGeneration) {
        _programmaticNavigationActive = false;
        _freeAnchor = null;
        _scheduleLayoutMaintenance();
      }
    }
  }

  Future<bool> _animateToOldest({
    required Duration duration,
    required Curve curve,
  }) async {
    final position = _dimensionedPosition;
    if (_messageIds.isEmpty || position == null) return false;
    if (_programmaticNavigationActive) {
      _cancelProgrammaticNavigation();
    }
    final generation = ++_navigationGeneration;
    _programmaticNavigationActive = true;
    _freeAnchor = null;
    try {
      await _scrollController.animateTo(
        position.minScrollExtent,
        duration: duration,
        curve: curve,
      );
      return await _settleAtOldest(generation);
    } finally {
      if (mounted && generation == _navigationGeneration) {
        _programmaticNavigationActive = false;
        _freeAnchor = null;
        _scheduleLayoutMaintenance();
      }
    }
  }

  Future<bool> _jumpToOldest() async {
    final position = _dimensionedPosition;
    if (_messageIds.isEmpty || position == null) return false;
    _cancelProgrammaticNavigation();
    final generation = _navigationGeneration;
    _programmaticNavigationActive = true;
    _freeAnchor = null;
    try {
      position.jumpTo(position.minScrollExtent);
      return await _settleAtOldest(generation);
    } finally {
      if (mounted && generation == _navigationGeneration) {
        _programmaticNavigationActive = false;
        _freeAnchor = null;
        _scheduleLayoutMaintenance();
      }
    }
  }

  Future<bool> _settleAtOldest(int generation) async {
    final binding = WidgetsBinding.instance;
    for (var attempt = 0; attempt < _maxOldestSettleAttempts; attempt += 1) {
      if (!mounted || generation != _navigationGeneration) return false;
      final position = _dimensionedPosition;
      if (position == null) return false;
      final target = position.minScrollExtent;
      if ((position.pixels - target).abs() > _geometryEpsilon) {
        position.jumpTo(target);
      }
      binding.scheduleFrame();
      await binding.endOfFrame;
      if (!mounted || generation != _navigationGeneration) return false;
      final settledPosition = _dimensionedPosition;
      if (settledPosition != null &&
          (settledPosition.pixels - settledPosition.minScrollExtent).abs() <=
              _geometryEpsilon &&
          _rowRect(_messageIds.first) != null) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _moveMessageToTop(
    String messageId, {
    required Duration duration,
    required Curve curve,
  }) async {
    if (!_messageIdSet.contains(messageId) || _dimensionedPosition == null) {
      return false;
    }
    if (_programmaticNavigationActive) {
      _cancelProgrammaticNavigation();
    }
    final generation = ++_navigationGeneration;
    _programmaticNavigationActive = true;
    try {
      final target = await _seekTargetOffsetForMessageTop(
        messageId,
        generation,
      );
      if (target == null || generation != _navigationGeneration) return false;
      if (!mounted || _dimensionedPosition == null) return false;
      await _scrollController.animateTo(
        target,
        duration: duration,
        curve: curve,
      );
    } finally {
      if (mounted && generation == _navigationGeneration) {
        _programmaticNavigationActive = false;
        _freeAnchor = null;
        _scheduleLayoutMaintenance();
      }
    }
    return mounted && generation == _navigationGeneration;
  }

  Future<bool> _jumpMessageToTop(String messageId) async {
    if (!_messageIdSet.contains(messageId) || _dimensionedPosition == null) {
      return false;
    }
    final target = _targetOffsetForMessageTop(messageId);
    _cancelProgrammaticNavigation();
    _freeAnchor = null;
    if (target != null) {
      _scrollController.position.jumpTo(target);
      _scheduleLayoutMaintenance();
      return true;
    }
    final generation = ++_navigationGeneration;
    _programmaticNavigationActive = true;
    return _seekAndJumpMessageToTop(messageId, generation);
  }

  Future<bool> _seekAndJumpMessageToTop(
    String messageId,
    int generation,
  ) async {
    try {
      final target = await _seekTargetOffsetForMessageTop(
        messageId,
        generation,
      );
      if (target == null || generation != _navigationGeneration) return false;
      if (!mounted || _dimensionedPosition == null) return false;
      _scrollController.position.jumpTo(target);
      return true;
    } finally {
      if (mounted && generation == _navigationGeneration) {
        _programmaticNavigationActive = false;
        _freeAnchor = null;
        _scheduleLayoutMaintenance();
      }
    }
  }

  Future<double?> _seekTargetOffsetForMessageTop(
    String messageId,
    int generation,
  ) async {
    if (!mounted || generation != _navigationGeneration) return null;
    final targetIndex = _messageIndexById[messageId];
    if (targetIndex == null) return null;
    final entryPosition = _dimensionedPosition;
    if (entryPosition == null) return null;
    final entryOffset = entryPosition.pixels;
    _seekEntryOffset = entryOffset;
    _seekEntryGeneration = generation;
    void clearEntryOffset() {
      if (_seekEntryGeneration != generation) return;
      _seekEntryOffset = null;
      _seekEntryGeneration = null;
    }

    void restoreEntryOffset() {
      if (!mounted || generation != _navigationGeneration) return;
      final position = _dimensionedPosition;
      if (position == null) {
        clearEntryOffset();
        return;
      }
      position.jumpTo(
        entryOffset
            .clamp(position.minScrollExtent, position.maxScrollExtent)
            .toDouble(),
      );
      clearEntryOffset();
    }

    final binding = WidgetsBinding.instance;
    final initialRowRects = _mountedRowRectSnapshot();
    final visibleIndices = _visibleMessageIds(null, initialRowRects)
        .map((id) => _messageIndexById[id])
        .whereType<int>()
        .toList(growable: false);
    final nearestIndex = visibleIndices.isEmpty
        ? _centerIndex
        : visibleIndices.reduce(
            (nearest, candidate) =>
                (candidate - targetIndex).abs() < (nearest - targetIndex).abs()
                ? candidate
                : nearest,
          );
    final indexDistance = (targetIndex - nearestIndex).abs();
    final attemptBudget = math.min(
      _maxSeekAttempts,
      math.max(_minSeekAttempts, indexDistance + 2),
    );
    for (var attempt = 0; attempt < attemptBudget; attempt += 1) {
      if (!mounted || generation != _navigationGeneration) return null;
      final target = _targetOffsetForMessageTop(messageId);
      if (target != null) {
        clearEntryOffset();
        return target;
      }
      final position = _dimensionedPosition;
      if (position == null) {
        restoreEntryOffset();
        return null;
      }
      final rowRects = _mountedRowRectSnapshot();
      final attemptVisibleIndices = _visibleMessageIds(null, rowRects)
          .map((id) => _messageIndexById[id])
          .whereType<int>()
          .toList(growable: false);
      final direction = _seekDirectionForMessage(
        targetIndex,
        attemptVisibleIndices,
      );
      final next = (position.pixels + direction * position.viewportDimension)
          .clamp(position.minScrollExtent, position.maxScrollExtent)
          .toDouble();
      if ((next - position.pixels).abs() <= _geometryEpsilon) {
        restoreEntryOffset();
        return null;
      }
      position.jumpTo(next);
      binding.scheduleFrame();
      await binding.endOfFrame;
      if (!mounted || generation != _navigationGeneration) return null;
    }
    if (!mounted || generation != _navigationGeneration) return null;
    final target = _targetOffsetForMessageTop(messageId);
    if (target == null) {
      restoreEntryOffset();
      DebugLogger.log(
        'timeline-seek-exhausted',
        scope: 'chat/timeline/viewport',
        data: {
          'targetIndex': targetIndex,
          'messageCount': _messageIds.length,
          'attemptBudget': attemptBudget,
        },
      );
    } else {
      clearEntryOffset();
    }
    return target;
  }

  int _seekDirectionForMessage(int targetIndex, List<int> visibleIndices) {
    if (visibleIndices.isNotEmpty) {
      final firstVisible = visibleIndices.reduce(math.min);
      final lastVisible = visibleIndices.reduce(math.max);
      if (targetIndex < firstVisible) return -1;
      if (targetIndex > lastVisible) return 1;
    }
    return targetIndex < _centerIndex ? -1 : 1;
  }

  double? _targetOffsetForMessageTop(String messageId) {
    final position = _dimensionedPosition;
    if (position == null) return null;
    final rect = _rowRect(messageId);
    final viewport = _viewportRect;
    if (rect == null || viewport == null) return null;
    return (position.pixels +
            rect.top -
            (viewport.top + widget.topContentInset))
        .clamp(position.minScrollExtent, position.maxScrollExtent)
        .toDouble();
  }

  void _cancelProgrammaticNavigation({bool restoreSeekEntryOffset = false}) {
    final wasActive = _programmaticNavigationActive;
    final entryOffset =
        restoreSeekEntryOffset && _seekEntryGeneration == _navigationGeneration
        ? _seekEntryOffset
        : null;
    _seekEntryOffset = null;
    _seekEntryGeneration = null;
    _navigationGeneration += 1;
    _programmaticNavigationActive = false;
    if (wasActive && _scrollController.hasClients) {
      final position = _scrollController.position;
      position.jumpTo(
        entryOffset
                ?.clamp(position.minScrollExtent, position.maxScrollExtent)
                .toDouble() ??
            position.pixels,
      );
    }
  }

  void _handleUserDragStart() {
    if (_userDragging) return;
    _userDragging = true;
    _anchorCorrectionAttempts = 0;
    _centerRecoveryPending = false;
    _cancelProgrammaticNavigation(restoreSeekEntryOffset: true);
    _freeAnchor = _captureVisibleMaintenanceAnchor();
    widget.onUserDragStart();
  }

  void _handleUserDragEnd() {
    if (!_userDragging) return;
    _userDragging = false;
    _anchorCorrectionAttempts = 0;
    _freeAnchor = _captureVisibleMaintenanceAnchor();
    widget.onUserDragEnd();
    _refreshTriggered = false;
    _trailingOverscroll = 0;
    _scheduleLayoutMaintenance();
  }

  void _resetRefreshGesture() {
    _refreshGeneration += 1;
    _refreshTriggered = false;
    _trailingOverscroll = 0;
    if (_refreshActive) {
      _refreshActive = false;
      if (mounted) setState(() {});
    }
  }

  void _handleTrailingOverscroll(OverscrollNotification notification) {
    if (!_userDragging || widget.isLoadingOlder || _refreshActive) {
      _trailingOverscroll = 0;
      return;
    }
    if (notification.metrics.extentAfter > 1) {
      _trailingOverscroll = 0;
      return;
    }
    _trailingOverscroll = math.max(
      0,
      _trailingOverscroll + notification.overscroll,
    );
    if (_refreshTriggered || _trailingOverscroll < _refreshThreshold) return;
    _refreshTriggered = true;
    final generation = ++_refreshGeneration;
    setState(() => _refreshActive = true);
    unawaited(
      Future<void>.sync(widget.onTrailingRefresh)
          .timeout(_trailingRefreshTimeout)
          .catchError((Object error, StackTrace stackTrace) {
            DebugLogger.error(
              error is TimeoutException
                  ? 'trailing-refresh-timeout'
                  : 'trailing-refresh-failed',
              scope: 'chat/timeline/viewport',
              error: error,
              stackTrace: stackTrace,
            );
          })
          .whenComplete(() {
            if (!mounted || generation != _refreshGeneration) return;
            setState(() => _refreshActive = false);
          }),
    );
  }

  bool _handleScrollNotification(ScrollNotification notification) {
    if (notification.depth != 0) return false;
    if (notification is ScrollStartNotification &&
        notification.dragDetails != null) {
      _handleUserDragStart();
    } else if (notification is OverscrollNotification) {
      _handleTrailingOverscroll(notification);
    } else if (notification is ScrollEndNotification) {
      _handleUserDragEnd();
    } else if (notification is UserScrollNotification) {
      // Pointer-signal scrolling (mouse wheels and trackpads) has no
      // dragDetails, but it does publish a non-idle user direction. Driven
      // animateTo activity does not, so it cannot steal manual ownership.
      //
      // direction == idle is deliberately NOT treated as drag end: Flutter
      // publishes it when the ballistic phase STARTS (goBallistic), not when
      // motion stops. Ending the drag there ran mode flips and jump-to-latest
      // arming mid-fling; ScrollEndNotification above fires at actual rest
      // for drags, flings, and pointer-signal scrolling alike.
      if (notification.direction != ScrollDirection.idle) {
        _handleUserDragStart();
      }
    }
    return false;
  }

  Widget _buildRow(BuildContext context, int chronologicalIndex) {
    final entry = _timelineEntries[chronologicalIndex];
    final id = entry.id;
    final cached = _rowWidgetCache[id];
    if (cached != null &&
        cached.sourceIndex == entry.sourceIndex &&
        cached.rebuildKey == entry.rebuildKey) {
      return cached.widget;
    }
    final ownerGeneration = widget.ownerGeneration;
    final row = MeasureSize(
      key: ValueKey<int>(ownerGeneration),
      onChange: (size) {
        if (mounted &&
            widget.ownerGeneration == ownerGeneration &&
            _messageIdSet.contains(id)) {
          _rowExtents[id] = size.height;
        }
      },
      child: _MountedTimelineRow(
        key: _rowKeys[id],
        messageId: id,
        onMounted: _registerMountedRow,
        onUnmounted: _unregisterMountedRow,
        child: IndexedSemantics(
          index: chronologicalIndex,
          child: Builder(
            builder: (context) => widget.rowBuilder(context, entry.sourceIndex),
          ),
        ),
      ),
    );
    final builtRow = KeyedSubtree(key: _TimelineRowKey(id), child: row);
    _rowWidgetCache[id] = (
      sourceIndex: entry.sourceIndex,
      rebuildKey: entry.rebuildKey,
      widget: builtRow,
    );
    return builtRow;
  }

  int? _olderChildIndexForKey(Key key, int centerIndex) {
    if (key is! _TimelineRowKey) return null;
    final chronologicalIndex = _messageIndexById[key.value];
    if (chronologicalIndex == null || chronologicalIndex >= centerIndex) {
      return null;
    }
    return centerIndex - 1 - chronologicalIndex;
  }

  int? _centerChildIndexForKey(Key key, int centerIndex) {
    if (key is! _TimelineRowKey) return null;
    final chronologicalIndex = _messageIndexById[key.value];
    if (chronologicalIndex == null || chronologicalIndex < centerIndex) {
      return null;
    }
    return chronologicalIndex - centerIndex;
  }

  void _registerMountedRow(String messageId) {
    _mountedRowCounts.update(
      messageId,
      (count) => count + 1,
      ifAbsent: () => 1,
    );
  }

  void _unregisterMountedRow(String messageId) {
    final count = _mountedRowCounts[messageId];
    if (count == null) return;
    if (count <= 1) {
      _mountedRowCounts.remove(messageId);
    } else {
      _mountedRowCounts[messageId] = count - 1;
    }
  }

  @override
  Widget build(BuildContext context) {
    final centerIndex = _centerIndex;
    final shouldHide =
        (!_initialPositionResolved && !_initialEmptyFallbackVisible) ||
        widget.hideUntilSettled;
    return LayoutBuilder(
      builder: (context, constraints) {
        final viewportHeight = constraints.maxHeight;
        final anchor = !viewportHeight.isFinite || viewportHeight <= 0
            ? 0.0
            : (widget.topContentInset / viewportHeight).clamp(0.0, 1.0);
        return _buildViewport(
          centerIndex: centerIndex,
          anchor: anchor,
          shouldHide: shouldHide,
        );
      },
    );
  }

  Widget _buildViewport({
    required int centerIndex,
    required double anchor,
    required bool shouldHide,
  }) {
    final transcript = NotificationListener<ScrollMetricsNotification>(
      onNotification: (notification) {
        // A settled automatic pin owns a fixed pixel target and viewport-sized
        // support. Streamed row growth does not change either value, so avoid
        // remeasuring the whole transcript for every markdown extent update.
        // Attached latest-follow corrects its extent synchronously from the
        // custom ScrollPosition, so a post-frame pass would only schedule a
        // redundant second frame. Explicit widget/controller changes still
        // request maintenance.
        if (notification.depth == 0 &&
            !(widget.pinAutomatic &&
                _pinGeometryReported &&
                !_userDragging &&
                !_programmaticNavigationActive) &&
            !_maintainsLatestDuringLayout) {
          _scheduleLayoutMaintenance();
        }
        return false;
      },
      child: NotificationListener<ScrollNotification>(
        onNotification: _handleScrollNotification,
        child: Listener(
          behavior: HitTestBehavior.translucent,
          onPointerDown: (_) {
            _cancelProgrammaticNavigation(restoreSeekEntryOffset: true);
            _centerRecoveryPending = false;
            widget.onPointerDown();
          },
          child: CustomScrollView(
            key: const ValueKey<String>('actual_messages'),
            controller: _scrollController,
            center: _centerSliverKey,
            anchor: anchor,
            semanticChildCount: _messageIds.length,
            scrollCacheExtent: ScrollCacheExtent.pixels(widget.cacheExtent),
            keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
            physics: widget.physics,
            slivers: [
              SliverToBoxAdapter(
                child: SizedBox(
                  key: const ValueKey<String>('chat-oldest-edge-clearance'),
                  height: math.max(0, widget.topContentInset),
                ),
              ),
              if (widget.isLoadingOlder)
                const SliverToBoxAdapter(
                  child: Padding(
                    key: ValueKey<String>('older-messages-loading'),
                    padding: EdgeInsets.symmetric(vertical: 24),
                    child: Center(child: CircularProgressIndicator.adaptive()),
                  ),
                ),
              SliverPadding(
                padding: EdgeInsets.symmetric(
                  horizontal: widget.horizontalPadding,
                ),
                sliver: SliverList(
                  delegate: _TimelineRowDelegate(
                    (context, index) =>
                        _buildRow(context, centerIndex - 1 - index),
                    childCount: centerIndex,
                    findChildIndexCallback: (key) =>
                        _olderChildIndexForKey(key, centerIndex),
                    rowBuilder: widget.rowBuilder,
                    entries: _timelineEntries,
                    centerIndex: centerIndex,
                    ownerGeneration: widget.ownerGeneration,
                    rowExtents: _rowExtents,
                    reversed: true,
                  ),
                ),
              ),
              SliverPadding(
                key: _centerSliverKey,
                padding: EdgeInsets.symmetric(
                  horizontal: widget.horizontalPadding,
                ),
                sliver: SliverList(
                  delegate: _TimelineRowDelegate(
                    (context, index) => _buildRow(context, centerIndex + index),
                    childCount: _messageIds.length - centerIndex,
                    findChildIndexCallback: (key) =>
                        _centerChildIndexForKey(key, centerIndex),
                    rowBuilder: widget.rowBuilder,
                    entries: _timelineEntries,
                    centerIndex: centerIndex,
                    ownerGeneration: widget.ownerGeneration,
                    rowExtents: _rowExtents,
                    reversed: false,
                  ),
                ),
              ),
              if (widget.liveFooter case final liveFooter?)
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.horizontalPadding,
                  ),
                  sliver: SliverToBoxAdapter(
                    key: _liveFooterSliverKey,
                    child: liveFooter,
                  ),
                ),
              if (widget.trailingContent case final trailingContent?)
                SliverPadding(
                  padding: EdgeInsets.symmetric(
                    horizontal: widget.horizontalPadding,
                  ),
                  sliver: SliverToBoxAdapter(
                    key: _trailingContentSliverKey,
                    child: trailingContent,
                  ),
                ),
              // Measured remaining space is metadata only. The synthetic
              // support stays viewport-sized for the pin's lifetime; shrinking
              // it after every streamed layout would change maxScrollExtent
              // and make Flutter correct the transcript upward.
              SliverToBoxAdapter(
                child: SizedBox(key: _endSentinelKey, height: 0),
              ),
              SliverToBoxAdapter(
                key: _pinSpacerSliverKey,
                child: ValueListenableBuilder<double>(
                  valueListenable: _pinSupportSpace,
                  builder: (context, pinSupportSpace, _) {
                    return SizedBox(
                      key: const ValueKey<String>('chat-composer-spacer'),
                      height:
                          widget.bottomPadding +
                          (widget.pinnedUserMessageId == null
                              ? 0
                              : pinSupportSpace),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );

    final mediaQuery = MediaQuery.of(context);
    // Platform scrollbars read track padding from their nearest MediaQuery.
    // Restore the real metrics below them so message widgets stay unchanged.
    final scrollbarMediaQuery = mediaQuery.copyWith(
      padding: mediaQuery.padding.copyWith(
        top: widget.topContentInset,
        bottom: widget.scrollbarBottomInset,
      ),
    );
    final scrollbarChild = MediaQuery(data: mediaQuery, child: transcript);
    final scrollableTranscript = MediaQuery(
      data: scrollbarMediaQuery,
      child: PlatformInfo.isIOS
          ? CupertinoScrollbar(
              controller: _scrollController,
              child: scrollbarChild,
            )
          : Scrollbar(controller: _scrollController, child: scrollbarChild),
    );

    return Stack(
      key: _viewportKey,
      children: [
        Positioned.fill(
          child: Opacity(
            key: const ValueKey<String>('sliver-transcript-visibility'),
            opacity: shouldHide ? 0 : 1,
            child: ExcludeSemantics(
              excluding: shouldHide,
              child: IgnorePointer(
                key: const ValueKey<String>('sliver-transcript-interaction'),
                ignoring: shouldHide,
                child: scrollableTranscript,
              ),
            ),
          ),
        ),
        if (_refreshActive)
          Positioned(
            left: 0,
            right: 0,
            bottom: widget.bottomPadding,
            child: const IgnorePointer(
              child: Center(
                child: SizedBox.square(
                  dimension: 22,
                  child: CircularProgressIndicator.adaptive(strokeWidth: 2),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// SliverChildBuilderDelegate whose `shouldRebuild` defaults to true, which
/// made every shell rebuild (drag-start setState, keyboard insets, pin
/// transitions) rebuild every mounted row. Row content is derived entirely
/// from [rowBuilder] and [entries]; per-row Consumers pick up message-level
/// changes on their own, so identical inputs mean no rebuild is needed.
class _TimelineRowDelegate extends SliverChildBuilderDelegate {
  const _TimelineRowDelegate(
    super.builder, {
    required super.childCount,
    required super.findChildIndexCallback,
    required this.rowBuilder,
    required this.entries,
    required this.centerIndex,
    required this.ownerGeneration,
    required this.rowExtents,
    required this.reversed,
  }) : super(addSemanticIndexes: false);

  final ChatTimelineRowBuilder rowBuilder;
  final List<({String id, int sourceIndex, Object? rebuildKey})> entries;
  final int centerIndex;
  final int ownerGeneration;
  final Map<String, double> rowExtents;
  final bool reversed;

  // Cache bounded first estimates for never-laid-out rows. Flutter's default
  // would multiply one tall visible response across every unknown sibling.
  @override
  double? estimateMaxScrollOffset(
    int firstIndex,
    int lastIndex,
    double leadingScrollOffset,
    double trailingScrollOffset,
  ) {
    final childCount = reversed ? centerIndex : entries.length - centerIndex;
    if (lastIndex >= childCount - 1) return trailingScrollOffset;
    var estimate = trailingScrollOffset;
    final laidOutCount = lastIndex - firstIndex + 1;
    final fallbackExtent = laidOutCount <= 0
        ? 52.0
        : ((trailingScrollOffset - leadingScrollOffset) / laidOutCount).clamp(
            48.0,
            400.0,
          );
    // ponytail: O(loaded rows); cache suffix sums if this scan appears in profiles.
    for (var index = lastIndex + 1; index < childCount; index += 1) {
      final chronologicalIndex = reversed
          ? centerIndex - 1 - index
          : centerIndex + index;
      final id = entries[chronologicalIndex].id;
      final extent = rowExtents.putIfAbsent(id, () => fallbackExtent);
      estimate += extent;
    }
    return estimate;
  }

  @override
  bool shouldRebuild(covariant _TimelineRowDelegate oldDelegate) {
    return !identical(rowBuilder, oldDelegate.rowBuilder) ||
        !identical(entries, oldDelegate.entries) ||
        centerIndex != oldDelegate.centerIndex ||
        ownerGeneration != oldDelegate.ownerGeneration ||
        reversed != oldDelegate.reversed;
  }
}

class _MountedTimelineRow extends StatefulWidget {
  const _MountedTimelineRow({
    required this.messageId,
    required this.onMounted,
    required this.onUnmounted,
    required this.child,
    super.key,
  });

  final String messageId;
  final ValueChanged<String> onMounted;
  final ValueChanged<String> onUnmounted;
  final Widget child;

  @override
  State<_MountedTimelineRow> createState() => _MountedTimelineRowState();
}

class _MountedTimelineRowState extends State<_MountedTimelineRow> {
  @override
  void initState() {
    super.initState();
    widget.onMounted(widget.messageId);
  }

  @override
  void didUpdateWidget(covariant _MountedTimelineRow oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.messageId == widget.messageId) return;
    oldWidget.onUnmounted(oldWidget.messageId);
    widget.onMounted(widget.messageId);
  }

  @override
  void dispose() {
    widget.onUnmounted(widget.messageId);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
