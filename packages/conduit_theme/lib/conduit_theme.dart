/// The tweakcn palette registry, shared by the Flutter app and the desktop UI.
///
/// Pure Dart with no Flutter and no `dart:io`, so it compiles with
/// `dart compile js` and can be imported from the renderer. The Flutter side
/// wraps the ARGB integers in `Color`; the desktop side turns them into CSS
/// custom properties.
library;

export 'src/css.dart';
export 'src/palette.dart';
export 'src/registry.dart';
