import 'package:conduit/l10n/app_localizations.dart';

import '../../../core/services/native_sheet_bridge.dart';
import '../../../core/utils/native_sheet_utils.dart'
    show buildNativeLoadingDetail;

/// Prefix of a push target's page of Settings: its status, the fix it
/// needs, a test and its options. The target's URI-encoded scope follows.
const pushTargetPagePrefix = 'push-target-page:';

/// The page of the push target [scope].
String pushTargetPageId(String scope) =>
    '$pushTargetPagePrefix${Uri.encodeComponent(scope)}';

/// The scope page [pageId] is for, or null when it is no push target's.
String? pushTargetScopeOf(String pageId) =>
    pageId.startsWith(pushTargetPagePrefix)
    ? Uri.decodeComponent(pageId.substring(pushTargetPagePrefix.length))
    : null;

/// The page "How Push Stays Private".
const pushPrivacyPageId = 'push-privacy';

/// Row ids of a target's page; the target's URI-encoded scope follows.
const pushTargetActionPrefix = 'push-target-action:';
const pushTargetTestPrefix = 'push-target-test:';
const pushTargetUsePrefix = 'push-target-use:';

/// Prefix of a "Replies From" row; the URI-encoded scope, a colon and the
/// origin's name follow.
const pushTargetOriginPrefix = 'push-target-origin:';

/// Control id of an Open WebUI target's Sign In row, with the target's scope
/// as its value. The sheet closes first: signing in is a flow of its own.
const pushTargetSignInActionId = 'push-target-sign-in';

/// The item in an account's or connection's row menu that opens its push
/// target's page, shown while its push needs the user.
NativeSheetRowAction pushSettingsRowAction(
  AppLocalizations l10n,
  String scope,
) => NativeSheetRowAction(
  id: pushTargetPageId(scope),
  label: l10n.pushSettingsMenuAction,
  sfSymbol: 'bell.badge',
  detailId: pushTargetPageId(scope),
);

/// The page of push target [scope] as it waits to be filled in, so a row or
/// row menu item can open it.
NativeSheetDetailConfig buildPushTargetLoadingPage(
  AppLocalizations l10n,
  String scope,
) => buildNativeLoadingDetail(
  l10n: l10n,
  id: pushTargetPageId(scope),
  title: l10n.pushSectionTitle,
);
