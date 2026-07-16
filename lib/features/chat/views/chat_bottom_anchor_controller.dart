class ChatBottomAnchorController {
  ChatBottomAnchorController({
    required this.showThreshold,
    required this.hideThreshold,
  }) : assert(showThreshold > hideThreshold);

  final double showThreshold;
  final double hideThreshold;

  bool isUserInteractingWithScroll = false;
  bool isAnchoredToBottom = true;

  bool updateAnchor({
    required bool hasScrollableContent,
    required double distanceFromBottom,
  }) {
    isAnchoredToBottom =
        !hasScrollableContent || distanceFromBottom <= hideThreshold;
    return isAnchoredToBottom;
  }

  bool shouldShowScrollToBottom({
    required bool currentlyShowing,
    required bool hasScrollableContent,
    required double distanceFromBottom,
  }) {
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

  void detachByUser() {
    isAnchoredToBottom = false;
  }

  void resetForDetachedScroll() {
    isAnchoredToBottom = true;
    isUserInteractingWithScroll = false;
  }
}

bool shouldKeepConversationBottomAnchoredOnContentSizeChange({
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  return isAnchoredToBottom && !isUserInteractingWithScroll && !wantsPinToTop;
}
