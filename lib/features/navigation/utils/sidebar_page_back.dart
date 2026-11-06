import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../shared/services/navigation_service.dart';

/// Whether pages the sidebar opens go back to the previous page, rather than
/// leaving the sidebar to lead everywhere.
///
/// The sliding sidebar opens Notes, Terminal, Channels, folders and their
/// details over the chat, so they lead back to it.
bool sidebarPagesGoBack(WidgetRef ref) =>
    ref.watch(appSettingsProvider.select((s) => s.slidingSidebarEnabled));

/// Goes back from a page the sidebar opened: to the page before it, or to
/// [fallback] when none is known. [beforeBack], such as saving an edit, can
/// keep the page open by returning false.
Future<void> goBackFromSidebarPage({
  required String fallback,
  Future<bool> Function()? beforeBack,
}) async {
  final route = NavigationService.currentRoute;
  final revision = NavigationService.currentRouteRevision;
  if (beforeBack != null && !await beforeBack()) return;
  // The person may have moved on while the page got ready to leave.
  if (NavigationService.currentRoute != route ||
      NavigationService.currentRouteRevision != revision) {
    return;
  }
  NavigationService.returnToPreviousPage(fallback: fallback);
}
