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

    if (_hasUnverifiedStickyContentChange &&
        isAnchoredToBottom &&
        !isUserInteractingWithScroll) {
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
    if (_hasUnverifiedStickyContentChange &&
        isAnchoredToBottom &&
        !isUserInteractingWithScroll) {
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
    required double scrollDelta,
  }) {
    if (nearBottom || !isAnchoredToBottom) {
      return false;
    }
    if (!_hasUnverifiedStickyContentChange) {
      return true;
    }
    return scrollDelta.abs() >= userScrollAwayThreshold;
  }

  void verifyStickyCorrection({required bool nearBottom}) {
    if (nearBottom) {
      isAnchoredToBottom = true;
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
