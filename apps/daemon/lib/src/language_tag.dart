import 'dart:io' show Platform;

import 'package:conduit_core/providers/app_providers.dart';
import 'package:riverpod/riverpod.dart';

/// The window's language when chosen in settings, else the system's, as a
/// BCP-47 tag: `en_US.UTF-8` becomes `en-US`. For `{{USER_LANGUAGE}}`.
String userLanguageTag(ProviderContainer container) {
  String? chosen;
  try {
    chosen = container.read(optimizedStorageServiceProvider).getLocaleCode();
  } on Object {
    // No storage to ask (a test's container): the system's, then.
    chosen = null;
  }
  final raw = (chosen != null && chosen.isNotEmpty)
      ? chosen
      : Platform.localeName;
  final tag = raw.split('.').first.split('@').first.replaceAll('_', '-');
  return tag.isEmpty || tag == 'C' || tag == 'POSIX' ? 'en-US' : tag;
}
