import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workspace_navigation.dart';
import 'workspace_editor_scaffold.dart';

sealed class WorkspaceEditorTarget {
  const WorkspaceEditorTarget();

  factory WorkspaceEditorTarget.fromRoute({
    required WorkspaceRouteMode mode,
    required String? resourceId,
  }) {
    if (mode == WorkspaceRouteMode.create) {
      return const WorkspaceCreateEditorTarget();
    }
    final id = resourceId?.trim() ?? '';
    return id.isEmpty
        ? const WorkspaceInvalidEditorTarget()
        : WorkspaceExistingEditorTarget(id);
  }
}

final class WorkspaceCreateEditorTarget extends WorkspaceEditorTarget {
  const WorkspaceCreateEditorTarget();
}

final class WorkspaceExistingEditorTarget extends WorkspaceEditorTarget {
  const WorkspaceExistingEditorTarget(this.resourceId);

  final String resourceId;
}

final class WorkspaceInvalidEditorTarget extends WorkspaceEditorTarget {
  const WorkspaceInvalidEditorTarget();
}

typedef WorkspaceResourceDetailLoader<T> =
    AsyncValue<T?> Function(WidgetRef ref, String resourceId);
typedef WorkspaceResourceRetry =
    void Function(WidgetRef ref, String resourceId);

/// Resolves create versus existing-resource routes once for every editor.
class WorkspaceResourceEditorRoute<T> extends ConsumerWidget {
  const WorkspaceResourceEditorRoute({
    super.key,
    required this.title,
    required this.section,
    required this.mode,
    required this.resourceId,
    required this.errorMessage,
    required this.createBuilder,
    required this.detailLoader,
    required this.onRetry,
    required this.builder,
  });

  final String title;
  final WorkspaceSection section;
  final WorkspaceRouteMode mode;
  final String? resourceId;
  final String errorMessage;
  final Widget Function() createBuilder;
  final WorkspaceResourceDetailLoader<T> detailLoader;
  final WorkspaceResourceRetry onRetry;
  final Widget Function(T value) builder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = WorkspaceEditorTarget.fromRoute(
      mode: mode,
      resourceId: resourceId,
    );
    return switch (target) {
      WorkspaceCreateEditorTarget() => createBuilder(),
      WorkspaceInvalidEditorTarget() => WorkspaceEditorScaffold(
        title: title,
        section: section,
        mode: mode,
        errorMessage: errorMessage,
        child: const SizedBox.shrink(),
      ),
      WorkspaceExistingEditorTarget(:final resourceId) =>
        WorkspaceResourceEditorHost<T>(
          title: title,
          section: section,
          mode: mode,
          resourceId: resourceId,
          detail: detailLoader(ref, resourceId),
          errorMessage: errorMessage,
          onRetry: () => onRetry(ref, resourceId),
          builder: builder,
        ),
    };
  }
}

/// Canonical load/error/not-found boundary for workspace resource editors.
class WorkspaceResourceEditorHost<T> extends StatelessWidget {
  const WorkspaceResourceEditorHost({
    super.key,
    required this.title,
    required this.section,
    required this.mode,
    required this.resourceId,
    required this.detail,
    required this.errorMessage,
    required this.onRetry,
    required this.builder,
  });

  final String title;
  final WorkspaceSection section;
  final WorkspaceRouteMode mode;
  final String resourceId;
  final AsyncValue<T?> detail;
  final String errorMessage;
  final VoidCallback onRetry;
  final Widget Function(T value) builder;

  @override
  Widget build(BuildContext context) {
    return KeyedSubtree(
      key: ValueKey<String>('workspace-resource-$resourceId-${mode.name}'),
      child: detail.when(
        loading: () => _scaffold(isLoading: true),
        error: (_, _) =>
            _scaffold(errorMessage: errorMessage, onRetry: onRetry),
        data: (value) => value == null
            ? _scaffold(errorMessage: errorMessage, onRetry: onRetry)
            : builder(value),
      ),
    );
  }

  Widget _scaffold({
    bool isLoading = false,
    String? errorMessage,
    VoidCallback? onRetry,
  }) {
    return WorkspaceEditorScaffold(
      title: title,
      section: section,
      mode: mode,
      isLoading: isLoading,
      errorMessage: errorMessage,
      onRetry: onRetry,
      child: const SizedBox.shrink(),
    );
  }
}
