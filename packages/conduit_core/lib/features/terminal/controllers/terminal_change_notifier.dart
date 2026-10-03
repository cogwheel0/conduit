/// Listener bookkeeping for the terminal controllers, shaped like Flutter's
/// `ChangeNotifier` (`addListener`, `removeListener`, `notifyListeners`,
/// `dispose`) so widgets in either app subscribe the same way. The core is
/// Flutter-free, so it cannot use `package:flutter/foundation.dart`.
mixin TerminalChangeNotifier {
  final List<void Function()> _listeners = <void Function()>[];

  void addListener(void Function() listener) => _listeners.add(listener);

  void removeListener(void Function() listener) => _listeners.remove(listener);

  /// Calls every listener registered when the notification starts; a
  /// listener removed by an earlier one in the same pass is skipped.
  void notifyListeners() {
    if (_listeners.isEmpty) return;
    for (final listener in List<void Function()>.of(_listeners)) {
      if (_listeners.contains(listener)) listener();
    }
  }

  void dispose() => _listeners.clear();
}
