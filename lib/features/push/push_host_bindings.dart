import 'dart:convert' show utf8;
import 'dart:io' show gzip;

import 'package:conduit_core/features/push/services/openwebui_push_backend.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../l10n/app_localizations.dart';

/// Where the app bundles the Open WebUI Conduit Push function, gzipped.
///
/// Compressed because App Store upload validation refuses any bundled file
/// that reads as a Python script as unsigned code (ITMS-90035), whatever its
/// name or file mode.
const String kConduitPushFunctionAsset =
    'assets/server_plugins/openwebui_conduit_push.py.gz';

/// Loads the bundled function for one-tap installs, or null when the asset
/// is missing or has no version.
Future<OpenWebUiFunctionSource?> loadBundledConduitPushFunction() async {
  final data = await rootBundle.load(kConduitPushFunctionAsset);
  final bytes = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  return OpenWebUiFunctionSource.parse(utf8.decode(gzip.decode(bytes)));
}

/// The strings the platform shows pushes with when a push carries no title
/// of its own, or cannot be decrypted. Keys as `PushDisplayConfig.strings`.
Map<String, String> pushDisplayStrings(AppLocalizations l10n) => {
  'fallbackTitle': l10n.pushFallbackTitle,
  'fallbackBody': l10n.pushFallbackBody,
  'replyTitle': l10n.pushReplyTitle,
  'replyFailedTitle': l10n.pushReplyFailedTitle,
  'replyFailedBody': l10n.pushReplyFailedBody,
  'channelTitle': l10n.pushChannelTitle,
  'cronTitle': l10n.pushCronTitle,
  'testTitle': l10n.pushTestTitle,
  'testBody': l10n.pushTestBody,
};
