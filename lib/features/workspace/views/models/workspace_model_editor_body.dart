import 'package:flutter/material.dart';

import '../../../../shared/theme/theme_extensions.dart';

/// Composes independently owned presentation sections for a model draft.
final class WorkspaceModelEditorBody extends StatelessWidget {
  const WorkspaceModelEditorBody({
    super.key,
    required this.profileImage,
    required this.basicsSection,
    required this.promptSection,
    required this.advancedSection,
    required this.relationshipsSection,
  });

  final Widget profileImage;
  final Widget basicsSection;
  final Widget promptSection;
  final Widget advancedSection;
  final Widget relationshipsSection;

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
        basicsSection,
        const SizedBox(height: Spacing.xl),
        promptSection,
        const SizedBox(height: Spacing.xl),
        advancedSection,
        const SizedBox(height: Spacing.xl),
        relationshipsSection,
        const SizedBox(height: Spacing.xl),
      ],
    );
  }
}
