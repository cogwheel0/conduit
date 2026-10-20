/// The few `package:flutter/foundation.dart` names the chat pipeline was
/// written against, with Flutter's semantics, so its call sites stay
/// unchanged now that it lives in the core.
library;

/// A callback with no arguments and no result.
typedef VoidCallback = void Function();

/// Element-wise equality of two lists, as Flutter's `listEquals`.
bool listEquals<T>(List<T>? a, List<T>? b) {
  if (a == null) {
    return b == null;
  }
  if (b == null || a.length != b.length) {
    return false;
  }
  if (identical(a, b)) {
    return true;
  }
  for (var index = 0; index < a.length; index += 1) {
    if (a[index] != b[index]) {
      return false;
    }
  }
  return true;
}
