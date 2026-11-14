import 'package:conduit_core/features/workspace/models/workspace_prompt_command.dart';

/// What Duplicate names a copy of a workspace item: the copy's id (or a
/// prompt's command) and its name, with the localized [suffix] the editor
/// passes ("(copy)", "(Clone)"). A copy never carries the item's access
/// grants; the caller leaves them out.
///
/// Shared by the phone's editors and the desktop's `workspace.duplicate`,
/// so a copy made on either is named the same way.
abstract final class WorkspaceClone {
  /// A model's copy: `<id>-copy`.
  static String modelId(String id) => '$id-copy';

  /// A prompt's copy: its command and the suffix, slugged into a legal
  /// command (`summarize-copy`); `<command>-copy` when nothing is left. A
  /// suffix in a non-Latin script slugs to nothing (for example "（副本）"),
  /// which would leave a bare trailing hyphen, so "copy" stands in for it.
  static String promptCommand(String command, String suffix) {
    final base = WorkspacePromptCommand.strip(command);
    final token = WorkspacePromptCommand.slugify(suffix);
    final slug = WorkspacePromptCommand.slugify(
      '$base-${token.isEmpty ? 'copy' : token}',
    );
    return slug.isEmpty ? '$base-copy' : slug;
  }

  /// A tool's copy: `<id>_clone` (tool ids are Python identifiers).
  static String toolId(String id) => id.isEmpty ? 'tool_clone' : '${id}_clone';

  /// A skill's copy: `<id>_clone`.
  static String skillId(String id) =>
      id.isEmpty ? 'skill_clone' : '${id}_clone';

  /// The copy's name: the item's name and the suffix.
  static String name(String name, String suffix) => '$name $suffix';
}
