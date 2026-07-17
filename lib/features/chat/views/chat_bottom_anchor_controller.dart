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
    if (distanceFromBottom <= hideThreshold) {
      isAnchoredToBottom = true;
    } else if (hasScrollableContent) {
      isAnchoredToBottom = false;
    }
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

  void requestBottomAnchor() {
    isUserInteractingWithScroll = false;
    isAnchoredToBottom = true;
  }

  void resetForDetachedScroll() {
    isAnchoredToBottom = true;
    isUserInteractingWithScroll = false;
  }
}

/// Keeps a programmatic bottom scroll tied to the newest layout extent.
///
/// A user gesture cancels the generation so a completed animation can never
/// pull the viewport back after the user has taken control.
class ChatBottomScrollSettler {
  int _generation = 0;

  void cancel() {
    _generation += 1;
  }

  Future<void> animateToLatestBottom({
    required double initialBottom,
    required Future<void> Function(double target) animateTo,
    required bool Function() canSettle,
    required void Function() rearmBottomAnchor,
    required double Function() latestBottom,
    required double Function() currentOffset,
    required void Function(double target) jumpTo,
    required void Function() onSettled,
    required double correctionEpsilon,
  }) async {
    final generation = ++_generation;
    await animateTo(initialBottom);
    // A drag can complete ScrollController.animateTo immediately before its
    // ScrollStartNotification reaches the page. Yield once so that user input
    // can cancel this generation before it performs the final correction.
    await Future<void>.value();
    if (generation != _generation || !canSettle()) return;

    // Metrics emitted during the animation may have classified the viewport
    // as detached while it was still travelling toward the original target.
    rearmBottomAnchor();
    final target = latestBottom();
    if (!target.isFinite || target <= 0) return;
    if ((currentOffset() - target).abs() >= correctionEpsilon) {
      jumpTo(target);
    }
    onSettled();
  }
}

bool shouldKeepConversationBottomAnchoredOnContentSizeChange({
  required bool isAnchoredToBottom,
  required bool isUserInteractingWithScroll,
  required bool wantsPinToTop,
}) {
  return isAnchoredToBottom && !isUserInteractingWithScroll && !wantsPinToTop;
}
