import 'package:material_ui/material_ui.dart';

/// Tracks whether a markdown body's render tree is complete.
///
/// Chunked block inflation reveals a very large settled body across frames.
/// While any chunked region under a body is still filling, the body must not
/// be wrapped in a SelectionArea: mutating children under one triggers
/// concurrent-modification errors in Flutter's selection system. Incomplete
/// regions register on the nearest enclosing gate; the owning widget listens
/// and re-arms selection once the reveal completes.
class MarkdownRenderGate extends ChangeNotifier {
  int _incompleteRegions = 0;

  bool get isComplete => _incompleteRegions == 0;

  void markRegionIncomplete() {
    _incompleteRegions += 1;
    if (_incompleteRegions == 1) notifyListeners();
  }

  void markRegionComplete() {
    if (_incompleteRegions == 0) {
      assert(false, 'markRegionComplete without matching incomplete.');
      return;
    }
    _incompleteRegions -= 1;
    if (_incompleteRegions == 0) notifyListeners();
  }
}

/// Exposes the enclosing body's [MarkdownRenderGate] to descendant chunked
/// regions.
class MarkdownRenderGateScope extends InheritedWidget {
  const MarkdownRenderGateScope({
    required this.gate,
    required super.child,
    super.key,
  });

  final MarkdownRenderGate gate;

  static MarkdownRenderGate? maybeOf(BuildContext context) => context
      .dependOnInheritedWidgetOfExactType<MarkdownRenderGateScope>()
      ?.gate;

  @override
  bool updateShouldNotify(MarkdownRenderGateScope oldWidget) =>
      !identical(gate, oldWidget.gate);
}
