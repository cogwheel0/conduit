import 'dart:async';

import 'package:conduit/core/persistence/preferences_store.dart';
import 'package:conduit/core/utils/debug_logger.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/platform/flutter_log_sink.dart';

/// Runs before every `flutter test` file.
///
/// `DebugLogger` has no destination of its own since WP-1.5 — the host
/// installs one. `main.dart` does that for the app; without this, tests would
/// silently stop logging, and the ones that assert on throttled log output
/// (chat_timeline_render_model_test) would have nothing to observe.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  DebugLogger.sink = const FlutterLogSink();
  // PreferencesStore takes its backing store from the host since WP-1.2.
  // Tests used to get `SharedPreferences.getInstance()` implicitly, served by
  // the plugin's own mock; installing the adapter here keeps that true
  // everywhere instead of in each of the 30-odd files that rely on it.
  PreferencesStore.installLoader(FlutterKeyValueStore.load);
  await testMain();
}
