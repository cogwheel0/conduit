import 'package:flutter/material.dart';

import '../../../../shared/theme/theme_extensions.dart';
import 'workspace_model_advanced_section.dart';
import 'workspace_model_basics_section.dart';
import 'workspace_model_editor_contract.dart';
import 'workspace_model_prompt_section.dart';
import 'workspace_model_relationships_section.dart';

/// Composes independently owned presentation sections for a model draft.
final class WorkspaceModelEditorBody extends StatelessWidget {
  const WorkspaceModelEditorBody({
    super.key,
    required this.state,
    required this.intents,
    required this.profileImage,
    required this.advancedExpanded,
    required this.onAdvancedChanged,
  });

  final WorkspaceModelEditorViewState state;
  final WorkspaceModelEditorIntents intents;
  final Widget profileImage;
  final bool advancedExpanded;
  final ValueChanged<bool> onAdvancedChanged;

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const Key('workspace-model-editor-body'),
      padding: EdgeInsets.fromLTRB(
        Spacing.pagePadding,
        Spacing.md,
        Spacing.pagePadding,
        Spacing.pagePadding + MediaQuery.paddingOf(context).bottom,
      ),
      children: [
        profileImage,
        const SizedBox(height: Spacing.xl),
        WorkspaceModelBasicsSection(state: state, intents: intents),
        const SizedBox(height: Spacing.xl),
        WorkspaceModelPromptSection(state: state, intents: intents),
        const SizedBox(height: Spacing.xl),
        WorkspaceModelAdvancedSection(
          state: state,
          intents: intents,
          expanded: advancedExpanded,
          onExpandedChanged: onAdvancedChanged,
        ),
        const SizedBox(height: Spacing.xl),
        WorkspaceModelRelationshipsSection(state: state, intents: intents),
        const SizedBox(height: Spacing.xl),
      ],
    );
  }
}
