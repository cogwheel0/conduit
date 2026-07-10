class ChatBottomAnchorController {
  ChatBottomAnchorController({
    required this.showThreshold,
    required this.hideThreshold,
    this.userScrollAwayThreshold = 24,
  });

  final double showThreshold;
  final double hideThreshold;
  final double userScrollAwayThreshold;

  bool isUserInteractingWithScroll = false;
  bool isAnchoredToBottom = true;
  bool _hasUnverifiedStickyContentChange = false;

  /// Whether an unverified sticky content change is still holding the view
  /// anchored to the bottom (and is not being overridden by user interaction).
  bool get _stickyLatchHolds =>
      _hasUnverifiedStickyContentChange &&
      isAnchoredToBottom &&
      !isUserInteractingWithScroll;

  bool updateAnchor({
    required bool hasScrollableContent,
    required double distanceFromBottom,
  }) {
    final nearBottom =
        !hasScrollableContent || distanceFromBottom <= hideThreshold;
    if (nearBottom) {
      isAnchoredToBottom = true;
      _hasUnverifiedStickyContentChange = false;
      return true;
    }

    // While a sticky content change is still pending, keep the view anchored
    // even mid-drag. Only shouldDetachForUserScrollAway (which honors
    // userScrollAwayThreshold) may break this latch, so a minor accidental drag
    // during streaming doesn't drop bottom anchoring.
    if (_hasUnverifiedStickyContentChange && isAnchoredToBottom) {
      return true;
    }

    isAnchoredToBottom = false;
    _hasUnverifiedStickyContentChange = false;
    return isAnchoredToBottom;
  }

  bool shouldShowScrollToBottom({
    required bool currentlyShowing,
    required bool hasScrollableContent,
    required double distanceFromBottom,
  }) {
    if (_stickyLatchHolds) {
      return false;
    }
    final farFromBottom = distanceFromBottom > showThreshold;
    final nearBottom = distanceFromBottom <= hideThreshold;
    return currentlyShowing
        ? !nearBottom && hasScrollableContent
        : farFromBottom && hasScrollableContent;
  }

  bool shouldKeepAnchoredOnContentSizeChange({required bool wantsPinToTop}) {
    return shouldKeepConversationBottomAnchoredOnContentSizeChange(
      isAnchoredToBottom: isAnchoredToBottom,
      isUserInteractingWithScroll: isUserInteractingWithScroll,
      wantsPinToTop: wantsPinToTop,
    );
  }

  bool prepareForStickyContentChange({required bool wantsPinToTop}) {
    final shouldKeepAnchored = shouldKeepAnchoredOnContentSizeChange(
      wantsPinToTop: wantsPinToTop,
    );
    if (shouldKeepAnchored) {
      _hasUnverifiedStickyContentChange = true;
    }
    return shouldKeepAnchored;
  }

  bool shouldDetachForUserScrollAway({
    required bool nearBottom,
    required double? scrollDelta,
  }) {
    if (nearBottom || !isAnchoredToBottom) {
      return false;
    }
    // Drag-start and directional notifications do not carry movement. Wait for
    // the first real ScrollUpdateNotification before deciding that the user
    // scrolled away; otherwise the handler defeats the threshold below by
    // inventing a synthetic delta at gesture start.
    if (scrollDelta == null) {
      return false;
    }
    if (!_hasUnverifiedStickyContentChange) {
      return true;
    }
    // Only detach when the user scrolls *away* from the bottom. In a
    // non-reversed list, that is a negative scrollDelta (offset decreases).
    // Using abs() previously also broke the sticky latch on intentional
    // downward drags back toward the bottom.
    return scrollDelta <= -userScrollAwayThreshold;
  }

  void verifyStickyCorrection({
    required bool nearBottom,
    bool isFinalAttempt = false,
  }) {
    if (nearBottom) {
      isAnchoredToBottom = true;
      _hasUnverifiedStickyContentChange = false;
    } else if (isFinalAttempt) {
      // The correction exhausted its attempts without reaching the bottom; drop
      // the latch so button visibility falls back to distance-based logic
      // instead of staying falsely pinned to the bottom.
      _hasUnverifiedStickyContentChange = false;
    }
  }

  void detachByUser() {
    isAnchoredToBottom = false;
    _hasUnverifiedStickyContentChange = false;
  }

  void resetForDetachedScroll() {
    isAnchoredToBottom = true;
    isUserInteractingWithScroll = false;
    _hasUnverifiedStickyContentChange = false;
  }
}

bool shouldKeepConversationBottomAnchoredOnContentSizeChange({
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  return isAnchoredToBottom && !isUserInteractingWithScroll && !wantsPinToTop;
}
