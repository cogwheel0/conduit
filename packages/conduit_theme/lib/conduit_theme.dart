/// The tweakcn palette registry, shared by the Flutter app and the desktop
/// app.
///
/// Pure Dart with no Flutter and no `dart:io`, so it compiles with
/// `dart compile js` and can be imported from a web renderer. The Flutter side
/// wraps the ARGB integers in `Color`; the desktop reads the same palettes,
/// plus its own surface tokens.
library;

export 'src/contrast.dart';
export 'src/palette.dart';
export 'src/registry.dart';
export 'src/surfaces.dart';
