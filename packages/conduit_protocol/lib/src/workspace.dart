import 'package:freezed_annotation/freezed_annotation.dart';

part 'workspace.freezed.dart';
part 'workspace.g.dart';

/// The five sections of the workspace.
enum WorkspaceKind { models, knowledge, prompts, tools, skills }

/// What the signed-in user may do in one section.
@freezed
abstract class WorkspaceSectionAccess with _$WorkspaceSectionAccess {
  const factory WorkspaceSectionAccess({
    @Default(false) bool manage,
    @Default(false) bool importItems,
    @Default(false) bool exportItems,
    @Default(false) bool share,
    @Default(false) bool sharePublicly,
  }) = _WorkspaceSectionAccess;

  factory WorkspaceSectionAccess.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceSectionAccessFromJson(json);
}

/// Reply to `workspace.capabilities`: which sections show, and what each
/// allows. A section the user cannot manage is left out of the navigation.
@freezed
abstract class WorkspaceAccess with _$WorkspaceAccess {
  const factory WorkspaceAccess({
    @Default(WorkspaceSectionAccess()) WorkspaceSectionAccess models,
    @Default(WorkspaceSectionAccess()) WorkspaceSectionAccess knowledge,
    @Default(WorkspaceSectionAccess()) WorkspaceSectionAccess prompts,
    @Default(WorkspaceSectionAccess()) WorkspaceSectionAccess tools,
    @Default(WorkspaceSectionAccess()) WorkspaceSectionAccess skills,

    /// Whether access can be granted to single users, not only groups.
    @Default(false) bool allowUserGrants,
    @Default(false) bool admin,
  }) = _WorkspaceAccess;

  factory WorkspaceAccess.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceAccessFromJson(json);
}

/// Who may read or write an item. A user grant to `*` makes it public.
@freezed
abstract class WorkspaceGrant with _$WorkspaceGrant {
  const factory WorkspaceGrant({
    /// `user` or `group`.
    @Default('user') String principalType,
    required String principalId,
    @Default(false) bool write,
  }) = _WorkspaceGrant;

  factory WorkspaceGrant.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceGrantFromJson(json);
}

/// An item as a section's list shows it.
@freezed
abstract class WorkspaceItem with _$WorkspaceItem {
  const factory WorkspaceItem({
    required WorkspaceKind kind,
    required String id,
    @Default('') String name,

    /// The line under the name: a description, or a prompt's `/command`.
    String? subtitle,
    String? ownerName,
    @Default(false) bool writeAccess,

    /// Null for kinds that cannot be switched off (knowledge, tools).
    bool? active,
    @Default(false) bool public,
    int? updatedAtMs,
    @Default(<String>[]) List<String> tags,
  }) = _WorkspaceItem;

  factory WorkspaceItem.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceItemFromJson(json);
}

/// Params for `workspace.list`. [more] loads the next page onto what this
/// daemon already holds for the section; otherwise the list starts over
/// with [query], [view] (`all`, `created`, `shared`) and, for knowledge,
/// [source].
@freezed
abstract class WorkspaceQuery with _$WorkspaceQuery {
  const factory WorkspaceQuery({
    required WorkspaceKind kind,
    @Default('') String query,
    @Default('all') String view,
    @Default('') String source,
    @Default(false) bool more,
  }) = _WorkspaceQuery;

  factory WorkspaceQuery.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceQueryFromJson(json);
}

/// Reply to `workspace.list`.
@freezed
abstract class WorkspacePage with _$WorkspacePage {
  const factory WorkspacePage({
    required WorkspaceKind kind,
    @Default(<WorkspaceItem>[]) List<WorkspaceItem> items,
    @Default(0) int total,
    @Default(false) bool hasMore,
  }) = _WorkspacePage;

  factory WorkspacePage.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePageFromJson(json);
}

/// Params naming one item.
@freezed
abstract class WorkspaceRef with _$WorkspaceRef {
  const factory WorkspaceRef({
    required WorkspaceKind kind,
    required String id,
  }) = _WorkspaceRef;

  factory WorkspaceRef.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceRefFromJson(json);
}

/// Something a model can be tied to, by id with a name to show.
@freezed
abstract class WorkspaceRelation with _$WorkspaceRelation {
  const factory WorkspaceRelation({
    required String id,
    @Default('') String name,
    String? subtitle,
  }) = _WorkspaceRelation;

  factory WorkspaceRelation.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceRelationFromJson(json);
}

/// A custom model, field by field. Keys the editor does not show are kept
/// by the daemon, which saves over the model as the server has it.
@freezed
abstract class WorkspaceModelDto with _$WorkspaceModelDto {
  const factory WorkspaceModelDto({
    @Default('') String id,
    @Default('') String name,
    String? baseModelId,
    @Default('') String description,
    String? imageUrl,
    @Default(<String>[]) List<String> tags,
    @Default('') String system,
    @Default(<String>[]) List<String> stop,
    @Default(<String>[]) List<String> suggestionPrompts,
    @Default(<String, bool>{}) Map<String, bool> capabilities,
    @Default(<WorkspaceRelation>[]) List<WorkspaceRelation> knowledge,
    @Default(<String>[]) List<String> toolIds,
    @Default(<String>[]) List<String> skillIds,
    @Default(<String>[]) List<String> filterIds,
    @Default(<String>[]) List<String> defaultFilterIds,
    @Default(<String>[]) List<String> actionIds,
    @Default(<String>[]) List<String> defaultFeatureIds,
    @Default('') String ttsVoice,

    /// The terminal chats with this model use, selected when the model is.
    @Default('') String terminalId,
    @Default(true) bool active,
    @Default(false) bool hidden,

    /// Everything in `params` besides the system prompt and stop words:
    /// temperature, context length and the rest, as Open WebUI names them.
    @Default(<String, dynamic>{}) Map<String, dynamic> params,
  }) = _WorkspaceModelDto;

  factory WorkspaceModelDto.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceModelDtoFromJson(json);
}

@freezed
abstract class WorkspaceKnowledgeDto with _$WorkspaceKnowledgeDto {
  const factory WorkspaceKnowledgeDto({
    @Default('') String id,
    @Default('') String name,
    @Default('') String description,
    @Default(0) int fileCount,
  }) = _WorkspaceKnowledgeDto;

  factory WorkspaceKnowledgeDto.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceKnowledgeDtoFromJson(json);
}

@freezed
abstract class WorkspacePromptDto with _$WorkspacePromptDto {
  const factory WorkspacePromptDto({
    @Default('') String id,

    /// The bare token, without the slash.
    @Default('') String command,
    @Default('') String name,
    @Default('') String content,
    @Default(<String>[]) List<String> tags,
    @Default(true) bool active,

    /// The version in production; a save makes a new one.
    String? versionId,

    /// Saved with the new version, for the history.
    String? commitMessage,

    /// Whether a save puts the new version in production. Off keeps
    /// production where it is and only records the version.
    @Default(true) bool production,
  }) = _WorkspacePromptDto;

  factory WorkspacePromptDto.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePromptDtoFromJson(json);
}

@freezed
abstract class WorkspaceToolDto with _$WorkspaceToolDto {
  const factory WorkspaceToolDto({
    @Default('') String id,
    @Default('') String name,
    @Default('') String description,

    /// The Python source.
    @Default('') String content,

    /// The functions the tool declares, by name.
    @Default(<String>[]) List<String> functions,
    @Default(false) bool hasValves,
    @Default(false) bool hasUserValves,

    /// The Open WebUI version the tool says it needs, when newer than the
    /// server's; saving is refused until the server catches up.
    String? requiresServerVersion,
  }) = _WorkspaceToolDto;

  factory WorkspaceToolDto.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceToolDtoFromJson(json);
}

@freezed
abstract class WorkspaceSkillDto with _$WorkspaceSkillDto {
  const factory WorkspaceSkillDto({
    @Default('') String id,
    @Default('') String name,
    @Default('') String description,
    @Default('') String content,
    @Default(true) bool active,
  }) = _WorkspaceSkillDto;

  factory WorkspaceSkillDto.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceSkillDtoFromJson(json);
}

/// One item with everything its editor shows. Exactly one of the kind
/// fields is set, the one [kind] names.
@freezed
abstract class WorkspaceDetail with _$WorkspaceDetail {
  const factory WorkspaceDetail({
    required WorkspaceKind kind,
    WorkspaceModelDto? model,
    WorkspaceKnowledgeDto? knowledge,
    WorkspacePromptDto? prompt,
    WorkspaceToolDto? tool,
    WorkspaceSkillDto? skill,
    @Default(<WorkspaceGrant>[]) List<WorkspaceGrant> grants,
    @Default(true) bool writeAccess,
    String? ownerName,
    int? updatedAtMs,
  }) = _WorkspaceDetail;

  factory WorkspaceDetail.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceDetailFromJson(json);
}

/// Params for `workspace.save`: [create] makes a new item from [detail];
/// otherwise it replaces the one with its id. Grants in [detail] are saved
/// with a new item; an existing one changes them through
/// `workspace.setAccess`.
@freezed
abstract class WorkspaceSave with _$WorkspaceSave {
  const factory WorkspaceSave({
    required WorkspaceDetail detail,
    @Default(false) bool create,

    /// For a prompt: save its name, command and tags only, without making
    /// a new version of its content.
    @Default(false) bool metadataOnly,
  }) = _WorkspaceSave;

  factory WorkspaceSave.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceSaveFromJson(json);
}

/// Params for `workspace.setAccess`.
@freezed
abstract class WorkspaceAccessEdit with _$WorkspaceAccessEdit {
  const factory WorkspaceAccessEdit({
    required WorkspaceKind kind,
    required String id,
    @Default(<WorkspaceGrant>[]) List<WorkspaceGrant> grants,
  }) = _WorkspaceAccessEdit;

  factory WorkspaceAccessEdit.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceAccessEditFromJson(json);
}

/// A user or group access can be granted to.
@freezed
abstract class WorkspacePrincipal with _$WorkspacePrincipal {
  const factory WorkspacePrincipal({
    /// `user` or `group`.
    required String type,
    required String id,
    @Default('') String name,
    String? email,
  }) = _WorkspacePrincipal;

  factory WorkspacePrincipal.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePrincipalFromJson(json);
}

/// Params for `workspace.principals`: users and groups matching [query].
/// With [ids], those principals by id instead, to name existing grants.
@freezed
abstract class WorkspacePrincipalQuery with _$WorkspacePrincipalQuery {
  const factory WorkspacePrincipalQuery({
    @Default('') String query,
    @Default(<String>[]) List<String> ids,
  }) = _WorkspacePrincipalQuery;

  factory WorkspacePrincipalQuery.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePrincipalQueryFromJson(json);
}

@freezed
abstract class WorkspacePrincipals with _$WorkspacePrincipals {
  const factory WorkspacePrincipals({
    @Default(<WorkspacePrincipal>[]) List<WorkspacePrincipal> items,
  }) = _WorkspacePrincipals;

  factory WorkspacePrincipals.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePrincipalsFromJson(json);
}

/// Params for `workspace.export`: one item, or with [id] null the whole
/// section.
@freezed
abstract class WorkspaceExportQuery with _$WorkspaceExportQuery {
  const factory WorkspaceExportQuery({
    required WorkspaceKind kind,
    String? id,
  }) = _WorkspaceExportQuery;

  factory WorkspaceExportQuery.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceExportQueryFromJson(json);
}

/// Reply to `workspace.export`: a file for the window to save. JSON as
/// [text]; a knowledge base is a zip, as [base64].
@freezed
abstract class WorkspaceExportFile with _$WorkspaceExportFile {
  const factory WorkspaceExportFile({
    required String filename,
    @Default('application/json') String mimeType,
    String? text,
    String? base64,
  }) = _WorkspaceExportFile;

  factory WorkspaceExportFile.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceExportFileFromJson(json);
}

/// Params for `workspace.import`: the text of an exported JSON file.
@freezed
abstract class WorkspaceImport with _$WorkspaceImport {
  const factory WorkspaceImport({
    required WorkspaceKind kind,
    required String text,
  }) = _WorkspaceImport;

  factory WorkspaceImport.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceImportFromJson(json);
}

/// One item of an import that did not go in.
@freezed
abstract class WorkspaceImportFailure with _$WorkspaceImportFailure {
  const factory WorkspaceImportFailure({
    @Default('') String label,
    @Default('') String reason,
  }) = _WorkspaceImportFailure;

  factory WorkspaceImportFailure.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceImportFailureFromJson(json);
}

/// Reply to `workspace.import`.
@freezed
abstract class WorkspaceImportResult with _$WorkspaceImportResult {
  const factory WorkspaceImportResult({
    @Default(0) int imported,
    @Default(<WorkspaceImportFailure>[]) List<WorkspaceImportFailure> failed,
  }) = _WorkspaceImportResult;

  factory WorkspaceImportResult.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceImportResultFromJson(json);
}

/// Reply to `workspace.modelOptions`: what the model editor's pickers
/// offer.
@freezed
abstract class WorkspaceModelOptions with _$WorkspaceModelOptions {
  const factory WorkspaceModelOptions({
    @Default(<WorkspaceRelation>[]) List<WorkspaceRelation> baseModels,
    @Default(<WorkspaceRelation>[]) List<WorkspaceRelation> knowledge,
    @Default(<WorkspaceRelation>[]) List<WorkspaceRelation> tools,
    @Default(<WorkspaceRelation>[]) List<WorkspaceRelation> skills,
    @Default(<WorkspaceRelation>[]) List<WorkspaceRelation> filters,
    @Default(<WorkspaceRelation>[]) List<WorkspaceRelation> actions,
  }) = _WorkspaceModelOptions;

  factory WorkspaceModelOptions.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceModelOptionsFromJson(json);
}

/// One saved version of a prompt.
@freezed
abstract class WorkspacePromptVersion with _$WorkspacePromptVersion {
  const factory WorkspacePromptVersion({
    required String id,
    String? parentId,
    String? commitMessage,
    String? authorName,
    @Default(0) int createdAtMs,
    @Default('') String name,
    @Default('') String command,
    @Default('') String content,

    /// Whether this is the version in production.
    @Default(false) bool production,
  }) = _WorkspacePromptVersion;

  factory WorkspacePromptVersion.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePromptVersionFromJson(json);
}

/// Reply to `workspace.promptHistory`: newest first.
@freezed
abstract class WorkspacePromptHistory with _$WorkspacePromptHistory {
  const factory WorkspacePromptHistory({
    required String promptId,
    @Default(<WorkspacePromptVersion>[]) List<WorkspacePromptVersion> versions,
  }) = _WorkspacePromptHistory;

  factory WorkspacePromptHistory.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePromptHistoryFromJson(json);
}

/// Params naming one version of a prompt.
@freezed
abstract class WorkspacePromptVersionRef with _$WorkspacePromptVersionRef {
  const factory WorkspacePromptVersionRef({
    required String promptId,
    required String versionId,
  }) = _WorkspacePromptVersionRef;

  factory WorkspacePromptVersionRef.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePromptVersionRefFromJson(json);
}

/// Params for `workspace.promptDiff`.
@freezed
abstract class WorkspacePromptDiffQuery with _$WorkspacePromptDiffQuery {
  const factory WorkspacePromptDiffQuery({
    required String promptId,
    required String fromId,
    required String toId,
  }) = _WorkspacePromptDiffQuery;

  factory WorkspacePromptDiffQuery.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePromptDiffQueryFromJson(json);
}

/// Reply to `workspace.promptDiff`: the content as unified-diff lines,
/// each starting with `+`, `-` or a space.
@freezed
abstract class WorkspacePromptDiff with _$WorkspacePromptDiff {
  const factory WorkspacePromptDiff({
    @Default(<String>[]) List<String> lines,
    @Default(false) bool nameChanged,
  }) = _WorkspacePromptDiff;

  factory WorkspacePromptDiff.fromJson(Map<String, dynamic> json) =>
      _$WorkspacePromptDiffFromJson(json);
}

/// Params for `workspace.valves`: a tool's settings, or with [user] the
/// signed-in user's own.
@freezed
abstract class WorkspaceValvesQuery with _$WorkspaceValvesQuery {
  const factory WorkspaceValvesQuery({
    required String toolId,
    @Default(false) bool user,
  }) = _WorkspaceValvesQuery;

  factory WorkspaceValvesQuery.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceValvesQueryFromJson(json);
}

/// A tool's valves: the JSON schema the form is drawn from, and the
/// values. Also the params of `workspace.saveValves`.
@freezed
abstract class WorkspaceValves with _$WorkspaceValves {
  const factory WorkspaceValves({
    required String toolId,
    @Default(false) bool user,
    @Default(<String, dynamic>{}) Map<String, dynamic> schema,
    @Default(<String, dynamic>{}) Map<String, dynamic> values,
  }) = _WorkspaceValves;

  factory WorkspaceValves.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceValvesFromJson(json);
}

/// Params for `workspace.toolFromUrl`.
@freezed
abstract class WorkspaceUrl with _$WorkspaceUrl {
  const factory WorkspaceUrl({required String url}) = _WorkspaceUrl;

  factory WorkspaceUrl.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceUrlFromJson(json);
}

/// A folder in a knowledge base.
@freezed
abstract class WorkspaceDirectory with _$WorkspaceDirectory {
  const factory WorkspaceDirectory({
    required String id,
    @Default('') String name,
    String? parentId,
  }) = _WorkspaceDirectory;

  factory WorkspaceDirectory.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceDirectoryFromJson(json);
}

/// A file in a knowledge base.
@freezed
abstract class WorkspaceFile with _$WorkspaceFile {
  const factory WorkspaceFile({
    required String id,
    @Default('') String filename,
    String? contentType,
    int? size,
    int? updatedAtMs,

    /// `processing`, `failed`, or null once it is searchable.
    String? status,
    String? error,
  }) = _WorkspaceFile;

  factory WorkspaceFile.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceFileFromJson(json);
}

/// Params for `workspace.files`: one folder of a knowledge base, the top
/// when [directoryId] is empty. [more] loads its next page.
@freezed
abstract class WorkspaceFilesQuery with _$WorkspaceFilesQuery {
  const factory WorkspaceFilesQuery({
    required String knowledgeId,
    @Default('') String directoryId,
    @Default(false) bool more,
  }) = _WorkspaceFilesQuery;

  factory WorkspaceFilesQuery.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceFilesQueryFromJson(json);
}

/// Reply to `workspace.files`.
@freezed
abstract class WorkspaceFiles with _$WorkspaceFiles {
  const factory WorkspaceFiles({
    required String knowledgeId,
    @Default('') String directoryId,

    /// From the top down to this folder.
    @Default(<WorkspaceDirectory>[]) List<WorkspaceDirectory> breadcrumbs,
    @Default(<WorkspaceDirectory>[]) List<WorkspaceDirectory> directories,
    @Default(<WorkspaceFile>[]) List<WorkspaceFile> files,

    /// Files still being read in, or that failed to be.
    @Default(<WorkspaceFile>[]) List<WorkspaceFile> pending,
    @Default(0) int total,
    @Default(false) bool hasMore,
  }) = _WorkspaceFiles;

  factory WorkspaceFiles.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceFilesFromJson(json);
}

/// Params for `workspace.attachFiles`: files already uploaded through
/// `POST /upload`, put into a folder of a knowledge base.
@freezed
abstract class WorkspaceFilesAttach with _$WorkspaceFilesAttach {
  const factory WorkspaceFilesAttach({
    required String knowledgeId,
    @Default('') String directoryId,
    @Default(<String>[]) List<String> fileIds,
  }) = _WorkspaceFilesAttach;

  factory WorkspaceFilesAttach.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceFilesAttachFromJson(json);
}

enum WorkspaceFileOp { rename, move, reindex, remove, delete }

/// Params for `workspace.fileAction`. [remove] takes the file out of the
/// knowledge base; [delete] deletes the file itself as well.
@freezed
abstract class WorkspaceFileAction with _$WorkspaceFileAction {
  const factory WorkspaceFileAction({
    required String knowledgeId,
    required String fileId,
    required WorkspaceFileOp op,

    /// The new name, for [WorkspaceFileOp.rename].
    String? filename,

    /// The folder to move to, for [WorkspaceFileOp.move]; empty is the top.
    String? directoryId,
  }) = _WorkspaceFileAction;

  factory WorkspaceFileAction.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceFileActionFromJson(json);
}

enum WorkspaceDirectoryOp { create, rename, delete }

/// Params for `workspace.directoryAction`. A new folder goes in
/// [parentId], the top when empty.
@freezed
abstract class WorkspaceDirectoryAction with _$WorkspaceDirectoryAction {
  const factory WorkspaceDirectoryAction({
    required String knowledgeId,
    required WorkspaceDirectoryOp op,
    String? directoryId,
    @Default('') String parentId,
    @Default('') String name,
  }) = _WorkspaceDirectoryAction;

  factory WorkspaceDirectoryAction.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceDirectoryActionFromJson(json);
}

/// Payload of `workspace.changed`: a section's items changed, from this
/// window or another. [id] is the item, when it was one.
@freezed
abstract class WorkspaceChanged with _$WorkspaceChanged {
  const factory WorkspaceChanged({required WorkspaceKind kind, String? id}) =
      _WorkspaceChanged;

  factory WorkspaceChanged.fromJson(Map<String, dynamic> json) =>
      _$WorkspaceChangedFromJson(json);
}
