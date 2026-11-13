import 'package:meta/meta.dart';

import 'package:conduit_core/features/navigation/models/sidebar_navigation_model.dart';
import 'package:conduit_core/navigation/routes.dart';

/// What the session's account can use right now, in one snapshot: which
/// sidebar destinations exist, and the Open WebUI features the phone gates
/// its settings and composer on.
///
/// A host that cannot watch the core's providers itself (the Mac app, over
/// the daemon) gates on this, so it shows what the phone shows. Every flag
/// is false until its answer is known: a destination that appears and then
/// vanishes reads as broken, one that appears late does not.
@immutable
final class AccountFeatures {
  const AccountFeatures({
    this.sidebar = noSidebar,
    this.folders = false,
    this.calendar = false,
    this.automations = false,
    this.scheduledTasks = false,
    this.webhooks = false,
    this.memories = false,
    this.codeInterpreter = false,
    this.imageGeneration = false,
    this.webSearch = false,
    this.workspaceSections = const <WorkspaceSection>[],
  });

  /// No backend at all: no destination exists.
  static const SidebarTabAvailability noSidebar = SidebarTabAvailability(
    hermesOnly: false,
    hasOpenWebUi: false,
    hermesEnabled: false,
    notesEnabled: false,
    terminalEnabled: false,
    channelsEnabled: false,
  );

  final SidebarTabAvailability sidebar;

  /// Folders can be listed and made ([foldersAvailableProvider]).
  final bool folders;

  /// The calendar, on a server and account that allow it.
  final bool calendar;

  /// Scheduled tasks, on a server and account that allow them.
  final bool automations;

  /// Scheduled tasks are offered as a destination: [automations], and the
  /// app's Advanced setting is on ([scheduledTasksEntryVisibleProvider]).
  /// Turning Advanced off hides the entry only; the server keeps running
  /// the tasks.
  final bool scheduledTasks;

  /// Webhook destinations for notifications.
  final bool webhooks;

  /// The server's memories, for personalization.
  final bool memories;

  /// The server runs the code interpreter for this account (any model).
  final bool codeInterpreter;

  /// The account may generate images (any model).
  final bool imageGeneration;

  /// The server and the account allow web search (any model).
  final bool webSearch;

  /// The workspace sections the account may manage, in the workspace's
  /// order; empty when it may manage none.
  final List<WorkspaceSection> workspaceSections;

  /// The sidebar destinations that exist, in [sidebarTabOrder].
  List<SidebarTabId> get sidebarTabs => visibleSidebarTabs(sidebar);

  @override
  bool operator ==(Object other) =>
      other is AccountFeatures &&
      other.sidebar == sidebar &&
      other.folders == folders &&
      other.calendar == calendar &&
      other.automations == automations &&
      other.scheduledTasks == scheduledTasks &&
      other.webhooks == webhooks &&
      other.memories == memories &&
      other.codeInterpreter == codeInterpreter &&
      other.imageGeneration == imageGeneration &&
      other.webSearch == webSearch &&
      _sameSections(other.workspaceSections, workspaceSections);

  @override
  int get hashCode => Object.hash(
    sidebar,
    folders,
    calendar,
    automations,
    scheduledTasks,
    webhooks,
    memories,
    codeInterpreter,
    imageGeneration,
    webSearch,
    Object.hashAll(workspaceSections),
  );

  static bool _sameSections(
    List<WorkspaceSection> a,
    List<WorkspaceSection> b,
  ) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  @override
  String toString() =>
      'AccountFeatures(tabs: ${sidebarTabs.map((t) => t.name).join(',')}, '
      'folders: $folders, calendar: $calendar, automations: $automations, '
      'scheduledTasks: $scheduledTasks, '
      'webhooks: $webhooks, memories: $memories, '
      'codeInterpreter: $codeInterpreter, imageGeneration: $imageGeneration, '
      'webSearch: $webSearch, '
      'workspace: ${workspaceSections.map((s) => s.name).join(',')})';
}
