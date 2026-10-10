import 'package:conduit_core/features/push/services/openwebui_push_backend.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../../l10n/app_localizations.dart';

/// Where the app bundles the Open WebUI Conduit Push function.
const String kConduitPushFunctionAsset =
    'assets/server_plugins/openwebui_conduit_push.py';

/// Loads the bundled function for one-tap installs, or null when the asset
/// is missing or has no version.
Future<OpenWebUiFunctionSource?> loadBundledConduitPushFunction() async {
  final content = await rootBundle.loadString(kConduitPushFunctionAsset);
  return OpenWebUiFunctionSource.parse(content);
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
