import 'package:dio/dio.dart' show DioException;
import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/models/workspace_prompt_command.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart'
    show WorkspaceCollectionState;
import 'package:conduit_core/navigation/routes.dart';

/// What the workspace page shows for a route: the section itself, or a
/// status in its place.
enum WorkspaceGateStatus { ready, loading, denied, unsupported, error }

/// Resolves the workspace gate for [section] (null for `/workspace`, which
/// the router redirects to the first permitted section once the
/// capabilities load).
///
/// Reviewer mode is denied outright. While the capabilities load the page
/// shows its loading state, and a load failure is [WorkspaceGateStatus.unsupported]
/// when the server has no workspace endpoints (404/405).
WorkspaceGateStatus resolveWorkspaceGate({
  required bool reviewerMode,
  required AsyncValue<WorkspaceCapabilities> capabilities,
  required WorkspaceSection? section,
}) {
  if (reviewerMode) return WorkspaceGateStatus.denied;
  return capabilities.when(
    loading: () => WorkspaceGateStatus.loading,
    error: (error, _) => isWorkspaceUnsupportedError(error)
        ? WorkspaceGateStatus.unsupported
        : WorkspaceGateStatus.error,
    data: (value) {
      final permitted = permittedWorkspaceSections(value);
      if (section == null) {
        return permitted.isEmpty
            ? WorkspaceGateStatus.denied
            : WorkspaceGateStatus.loading;
      }
      return permitted.contains(section)
          ? WorkspaceGateStatus.ready
          : WorkspaceGateStatus.denied;
    },
  );
}

/// Whether [error] means the server has no workspace API.
bool isWorkspaceUnsupportedError(Object error) {
  final status = error is DioException ? error.response?.statusCode : null;
  return status == 404 || status == 405;
}

/// The sections the loaded capabilities permit; none while they load or
/// after they fail.
List<WorkspaceSection> permittedWorkspaceSectionsOf(
  AsyncValue<WorkspaceCapabilities> capabilities,
) => capabilities.maybeWhen(
  data: permittedWorkspaceSections,
  orElse: () => const <WorkspaceSection>[],
);

/// Whether the user may create resources in [section] (the create action).
bool canCreateInWorkspaceSection(
  AsyncValue<WorkspaceCapabilities> capabilities,
  WorkspaceSection section,
) => capabilities.maybeWhen(
  data: (value) => section.capabilities(value).manage,
  orElse: () => false,
);

/// The text of one collection row.
typedef WorkspaceCollectionRowText = ({
  String id,
  String title,
  String? subtitle,
});

/// The id, title and subtitle of a collection item: a model's base model,
/// a knowledge base's or skill's description, a prompt's `/command`, or a
/// tool's meta description.
WorkspaceCollectionRowText workspaceCollectionRowText(Object item) {
  return switch (item) {
    WorkspaceModelSummary() => (
      id: item.id,
      title: item.name,
      subtitle: item.baseModelId,
    ),
    WorkspaceKnowledgeSummary() => (
      id: item.id,
      title: item.name,
      subtitle: item.description,
    ),
    WorkspacePromptSummary() => (
      id: item.id,
      title: item.name,
      subtitle: item.command.isEmpty
          ? null
          : WorkspacePromptCommand.display(item.command),
    ),
    WorkspaceToolSummary() => (
      id: item.id,
      title: item.name,
      subtitle: item.meta['description']?.toString(),
    ),
    WorkspaceSkillSummary() => (
      id: item.id,
      title: item.name,
      subtitle: item.description,
    ),
    _ => throw ArgumentError.value(item, 'item', 'Not a workspace resource'),
  };
}

/// The title of a loaded detail resource, or null for anything else.
String? workspaceDetailTitle(Object? detail) {
  return switch (detail) {
    WorkspaceModelSummary() => detail.name,
    WorkspaceKnowledgeDetail() => detail.summary.name,
    WorkspacePromptSummary() => detail.name,
    WorkspaceToolSummary() => detail.name,
    WorkspaceSkillSummary() => detail.name,
    _ => null,
  };
}

/// What a collection pane shows.
enum WorkspaceCollectionContent { loading, error, empty, items }

/// A load failure with nothing loaded is an error; a failed refresh or page
/// keeps the items it has.
WorkspaceCollectionContent workspaceCollectionContent<T>(
  AsyncValue<WorkspaceCollectionState<T>> value,
) {
  return value.when(
    loading: () => WorkspaceCollectionContent.loading,
    error: (_, _) => WorkspaceCollectionContent.error,
    data: (collection) {
      if (collection.items.isEmpty) {
        return collection.error != null
            ? WorkspaceCollectionContent.error
            : WorkspaceCollectionContent.empty;
      }
      return WorkspaceCollectionContent.items;
    },
  );
}

/// Whether the search field shows: always while loading, and once loaded
/// when there is something to search or a query to clear.
bool workspaceCollectionShowsSearch<T>(
  AsyncValue<WorkspaceCollectionState<T>> value,
) => value.maybeWhen(
  data: (collection) =>
      collection.items.isNotEmpty || collection.query.isNotEmpty,
  orElse: () => true,
);

/// The knowledge collection's view filter as its menu shows it: `created`
/// or `shared`, and `''` (all) for anything else, including the notifier's
/// default `all`.
String workspaceKnowledgeViewFilter(String view) =>
    view == 'created' || view == 'shared' ? view : '';

/// How close to the end of a collection a scroll starts loading the next
/// page, in logical pixels.
const double workspaceLoadMoreThreshold = 320;

/// Whether a scroll at [offset] of [maxExtent] should load the next page.
bool workspaceCollectionShouldLoadMore({
  required double offset,
  required double maxExtent,
  required bool hasMore,
  required bool isLoadingMore,
}) =>
    hasMore &&
    !isLoadingMore &&
    offset >= maxExtent - workspaceLoadMoreThreshold;
