import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../workspace_navigation.dart';
import 'workspace_editor_scaffold.dart';

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
  final String? resourceId;
  final AsyncValue<T?>? detail;
  final String errorMessage;
  final VoidCallback onRetry;
  final Widget Function(T value) builder;

  @override
  Widget build(BuildContext context) {
    final id = resourceId;
    if (id == null || id.isEmpty || detail == null) {
      return _scaffold(errorMessage: errorMessage);
    }
    return detail!.when(
      loading: () => _scaffold(isLoading: true),
      error: (_, _) => _scaffold(errorMessage: errorMessage, onRetry: onRetry),
      data: (value) => value == null
          ? _scaffold(errorMessage: errorMessage, onRetry: onRetry)
          : builder(value),
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
