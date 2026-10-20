import 'package:checks/checks.dart';
import 'package:dio/dio.dart';
import 'package:riverpod/riverpod.dart';
import 'package:test/test.dart';

import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/models/workspace_collection_view.dart';
import 'package:conduit_core/features/workspace/models/workspace_knowledge.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:conduit_core/features/workspace/providers/workspace_providers.dart';
import 'package:conduit_core/navigation/routes.dart';

DioException _status(int code) {
  final request = RequestOptions(path: '/api/v1/users/permissions');
  return DioException(
    requestOptions: request,
    response: Response<void>(requestOptions: request, statusCode: code),
  );
}

const _promptsOnly = WorkspaceCapabilities(
  prompts: WorkspaceSectionCapabilities.all,
);

void main() {
  group('resolveWorkspaceGate', () {
    WorkspaceGateStatus gate(
      AsyncValue<WorkspaceCapabilities> capabilities, {
      WorkspaceSection? section = WorkspaceSection.prompts,
      bool reviewerMode = false,
    }) => resolveWorkspaceGate(
      reviewerMode: reviewerMode,
      capabilities: capabilities,
      section: section,
    );

    test('reviewer mode is denied whatever the capabilities', () {
      check(
        gate(const AsyncData(WorkspaceCapabilities.all), reviewerMode: true),
      ).equals(WorkspaceGateStatus.denied);
    });

    test('loading, and load failures by status', () {
      check(gate(const AsyncLoading())).equals(WorkspaceGateStatus.loading);
      check(gate(AsyncError(_status(404), StackTrace.empty)))
          .equals(WorkspaceGateStatus.unsupported);
      check(gate(AsyncError(_status(405), StackTrace.empty)))
          .equals(WorkspaceGateStatus.unsupported);
      check(gate(AsyncError(_status(500), StackTrace.empty)))
          .equals(WorkspaceGateStatus.error);
      check(gate(AsyncError(StateError('offline'), StackTrace.empty)))
          .equals(WorkspaceGateStatus.error);
    });

    test('a section is ready only when permitted', () {
      check(gate(const AsyncData(_promptsOnly)))
          .equals(WorkspaceGateStatus.ready);
      check(
        gate(const AsyncData(_promptsOnly), section: WorkspaceSection.models),
      ).equals(WorkspaceGateStatus.denied);
    });

    test('the bare workspace route waits for the redirect, or is denied', () {
      check(gate(const AsyncData(_promptsOnly), section: null))
          .equals(WorkspaceGateStatus.loading);
      check(gate(const AsyncData(WorkspaceCapabilities.none), section: null))
          .equals(WorkspaceGateStatus.denied);
    });
  });

  test('permitted sections and create follow loaded capabilities only', () {
    check(permittedWorkspaceSectionsOf(const AsyncData(_promptsOnly)))
        .deepEquals([WorkspaceSection.prompts]);
    check(permittedWorkspaceSectionsOf(const AsyncLoading())).isEmpty();
    check(
      canCreateInWorkspaceSection(
        const AsyncData(_promptsOnly),
        WorkspaceSection.prompts,
      ),
    ).isTrue();
    check(
      canCreateInWorkspaceSection(
        const AsyncData(_promptsOnly),
        WorkspaceSection.tools,
      ),
    ).isFalse();
    check(
      canCreateInWorkspaceSection(
        const AsyncLoading(),
        WorkspaceSection.prompts,
      ),
    ).isFalse();
  });

  test('row text per resource type', () {
    check(
      workspaceCollectionRowText(
        const WorkspaceModelSummary(
          id: 'm1',
          name: 'Model',
          userId: 'u',
          baseModelId: 'gpt-base',
        ),
      ),
    ).equals((id: 'm1', title: 'Model', subtitle: 'gpt-base'));
    check(
      workspaceCollectionRowText(
        const WorkspaceKnowledgeSummary(
          id: 'k1',
          name: 'Docs',
          userId: 'u',
          description: 'Handbook',
        ),
      ),
    ).equals((id: 'k1', title: 'Docs', subtitle: 'Handbook'));
    check(
      workspaceCollectionRowText(
        const WorkspacePromptSummary(
          id: 'p1',
          command: '//summarize',
          name: 'Summarize',
          content: '',
          userId: 'u',
        ),
      ),
    ).equals((id: 'p1', title: 'Summarize', subtitle: '/summarize'));
    check(
      workspaceCollectionRowText(
        const WorkspacePromptSummary(
          id: 'p2',
          command: '',
          name: 'Bare',
          content: '',
          userId: 'u',
        ),
      ).subtitle,
    ).isNull();
    check(
      workspaceCollectionRowText(
        const WorkspaceToolSummary(
          id: 't1',
          name: 'Tool',
          userId: 'u',
          meta: {'description': 'Does things'},
        ),
      ),
    ).equals((id: 't1', title: 'Tool', subtitle: 'Does things'));
    check(
      workspaceCollectionRowText(
        const WorkspaceSkillSummary(
          id: 's1',
          name: 'Skill',
          userId: 'u',
          description: 'Knows things',
        ),
      ),
    ).equals((id: 's1', title: 'Skill', subtitle: 'Knows things'));
    check(() => workspaceCollectionRowText('not a resource'))
        .throws<ArgumentError>();
  });

  test('detail titles', () {
    check(
      workspaceDetailTitle(
        const WorkspaceKnowledgeDetail(
          summary: WorkspaceKnowledgeSummary(id: 'k', name: 'KB', userId: 'u'),
        ),
      ),
    ).equals('KB');
    check(
      workspaceDetailTitle(
        const WorkspaceToolSummary(id: 't', name: 'Tool', userId: 'u'),
      ),
    ).equals('Tool');
    check(workspaceDetailTitle(null)).isNull();
    check(workspaceDetailTitle(42)).isNull();
  });

  group('workspaceCollectionContent', () {
    const item = WorkspaceSkillSummary(id: 's', name: 'S', userId: 'u');

    test('loading and error', () {
      check(
        workspaceCollectionContent<WorkspaceSkillSummary>(const AsyncLoading()),
      ).equals(WorkspaceCollectionContent.loading);
      check(
        workspaceCollectionContent<WorkspaceSkillSummary>(
          AsyncError(StateError('x'), StackTrace.empty),
        ),
      ).equals(WorkspaceCollectionContent.error);
    });

    test('a failure with no items is an error; with items it keeps them', () {
      check(
        workspaceCollectionContent(
          AsyncData(
            WorkspaceCollectionState<WorkspaceSkillSummary>(
              error: StateError('x'),
            ),
          ),
        ),
      ).equals(WorkspaceCollectionContent.error);
      check(
        workspaceCollectionContent(
          AsyncData(
            WorkspaceCollectionState<WorkspaceSkillSummary>(
              items: const [item],
              total: 1,
              error: StateError('x'),
            ),
          ),
        ),
      ).equals(WorkspaceCollectionContent.items);
      check(
        workspaceCollectionContent(
          const AsyncData(WorkspaceCollectionState<WorkspaceSkillSummary>()),
        ),
      ).equals(WorkspaceCollectionContent.empty);
    });

    test('search shows while loading, with items, or with a query', () {
      check(
        workspaceCollectionShowsSearch<WorkspaceSkillSummary>(
          const AsyncLoading(),
        ),
      ).isTrue();
      check(
        workspaceCollectionShowsSearch(
          const AsyncData(WorkspaceCollectionState<WorkspaceSkillSummary>()),
        ),
      ).isFalse();
      check(
        workspaceCollectionShowsSearch(
          const AsyncData(
            WorkspaceCollectionState<WorkspaceSkillSummary>(query: 'zz'),
          ),
        ),
      ).isTrue();
      check(
        workspaceCollectionShowsSearch(
          const AsyncData(
            WorkspaceCollectionState<WorkspaceSkillSummary>(items: [item]),
          ),
        ),
      ).isTrue();
    });
  });

  test('knowledge view filter maps the default and unknown views to all', () {
    check(workspaceKnowledgeViewFilter('all')).equals('');
    check(workspaceKnowledgeViewFilter('bogus')).equals('');
    check(workspaceKnowledgeViewFilter('created')).equals('created');
    check(workspaceKnowledgeViewFilter('shared')).equals('shared');
  });

  test('load more near the end, once, while more remain', () {
    bool loads({
      double offset = 700,
      bool hasMore = true,
      bool isLoadingMore = false,
    }) => workspaceCollectionShouldLoadMore(
      offset: offset,
      maxExtent: 1000,
      hasMore: hasMore,
      isLoadingMore: isLoadingMore,
    );

    check(loads()).isTrue();
    check(loads(offset: 679)).isFalse();
    check(loads(hasMore: false)).isFalse();
    check(loads(isLoadingMore: true)).isFalse();
  });
}
