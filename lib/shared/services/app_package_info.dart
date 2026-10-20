import 'package:package_info_plus/package_info_plus.dart';
import 'package:riverpod/riverpod.dart';

/// The running build's name, version and number.
///
/// Lives in the app rather than `app_providers`, because `package_info_plus`
/// is a Flutter plugin and was the single import keeping that file off the
/// portable side. Nothing in the core asks what version it is; only About
/// screens, the release-notes coordinator and the native profile sheet do,
/// and all of them are app-side already.
final packageInfoProvider = FutureProvider<PackageInfo>((ref) async {
  return PackageInfo.fromPlatform();
});
