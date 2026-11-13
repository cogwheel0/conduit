import 'access.dart';
import 'accounts.dart';
import 'auth.dart';
import 'capabilities.dart';
import 'chat_prompts.dart';
import 'channels.dart';
import 'chat_settings.dart';
import 'chats.dart';
import 'composer.dart';
import 'data.dart';
import 'direct.dart';
import 'events.dart';
import 'handoff.dart';
import 'handshake.dart';
import 'hermes.dart';
import 'mcp.dart';
import 'mcp_apps.dart';
import 'memories.dart';
import 'messages.dart';
import 'methods.dart';
import 'models.dart';
import 'notes.dart';
import 'profile.dart';
import 'prompts.dart';
import 'release_notes.dart';
import 'queue.dart';
import 'servers.dart';
import 'settings.dart';
import 'system.dart';
import 'terminal.dart';
import 'turns.dart';
import 'valves.dart';
import 'voice.dart';
import 'workspace.dart';

/// Decodes a JSON object into a DTO: a `fromJson` factory.
typedef JsonObjectDecoder<T> = T Function(Map<String, dynamic> json);

/// What one RPC method takes and answers with.
///
/// [P] and [R] are the DTOs; `void` means the method takes no params (any
/// `params` it is sent are ignored) or answers with nothing. The daemon
/// registers its handlers from these, and `tool/generate_rust.dart` reads
/// them to type the Rust client, so the two cannot disagree about a method.
final class ConduitMethodSpec<P, R> {
  const ConduitMethodSpec(this.name, {this.params, this.result});

  /// One of [ConduitMethods].
  final String name;

  /// Decodes the params; null when the method takes none.
  final JsonObjectDecoder<P>? params;

  /// Decodes the result; null when the method answers with nothing.
  final JsonObjectDecoder<R>? result;

  /// The params DTO's name, or null for none.
  String? get paramsType => params == null ? null : '$P';

  /// The result DTO's name, or null for none.
  String? get resultType => result == null ? null : '$R';

  @override
  String toString() =>
      'ConduitMethodSpec($name, ${paramsType ?? 'none'} -> '
      '${resultType ?? 'none'})';
}

/// What one event carries.
///
/// [T] is the payload DTO; `void` means the event has no payload (it is
/// sent as `{}`), and the window refetches whatever it names.
final class ConduitEventSpec<T> {
  const ConduitEventSpec(this.name, {this.payload, required this.scoped});

  /// One of [ConduitEvents].
  final String name;

  /// Decodes the payload; null when the event has none.
  final JsonObjectDecoder<T>? payload;

  /// Whether the event is published with an [EventEnvelope.scope]: such an
  /// event reaches only the windows subscribed to that scope. An unscoped
  /// one reaches every window whose event filter lets it through.
  final bool scoped;

  /// The payload DTO's name, or null for none.
  String? get payloadType => payload == null ? null : '$T';

  @override
  String toString() =>
      'ConduitEventSpec($name, ${payloadType ?? 'none'}, '
      '${scoped ? 'scoped' : 'unscoped'})';
}

/// Every RPC method, with its params and result.
///
/// [all] lists each one exactly once; the protocol tests hold it equal to
/// the names in [ConduitMethods].
abstract final class ConduitMethodSpecs {
  // system.*, events.*, ui.*

  static const systemHandshake =
      ConduitMethodSpec<HandshakeRequest, HandshakeResponse>(
        ConduitMethods.systemHandshake,
        params: HandshakeRequest.fromJson,
        result: HandshakeResponse.fromJson,
      );
  static const systemPing = ConduitMethodSpec<void, PongResult>(
    ConduitMethods.systemPing,
    result: PongResult.fromJson,
  );
  static const systemCapabilities = ConduitMethodSpec<void, Capabilities>(
    ConduitMethods.systemCapabilities,
    result: Capabilities.fromJson,
  );
  static const systemShutdown = ConduitMethodSpec<void, ShutdownResult>(
    ConduitMethods.systemShutdown,
    result: ShutdownResult.fromJson,
  );
  static const systemExportDiagnostics =
      ConduitMethodSpec<void, DiagnosticsExport>(
        ConduitMethods.systemExportDiagnostics,
        result: DiagnosticsExport.fromJson,
      );
  static const systemNetwork = ConduitMethodSpec<NetworkReport, OkResult>(
    ConduitMethods.systemNetwork,
    params: NetworkReport.fromJson,
    result: OkResult.fromJson,
  );
  static const eventsSubscribe =
      ConduitMethodSpec<EventSubscription, EventSubscription>(
        ConduitMethods.eventsSubscribe,
        params: EventSubscription.fromJson,
        result: EventSubscription.fromJson,
      );
  static const uiRespond = ConduitMethodSpec<UiResponse, AcceptedResult>(
    ConduitMethods.uiRespond,
    params: UiResponse.fromJson,
    result: AcceptedResult.fromJson,
  );

  // accounts.*, servers.*, auth.*

  static const accountsList = ConduitMethodSpec<void, AccountList>(
    ConduitMethods.accountsList,
    result: AccountList.fromJson,
  );
  static const accountsAdd = ConduitMethodSpec<AddAccount, AccountChangeResult>(
    ConduitMethods.accountsAdd,
    params: AddAccount.fromJson,
    result: AccountChangeResult.fromJson,
  );
  static const accountsCancelAdd = ConduitMethodSpec<void, AccountChangeResult>(
    ConduitMethods.accountsCancelAdd,
    result: AccountChangeResult.fromJson,
  );
  static const accountsSwitch =
      ConduitMethodSpec<AccountRef, AccountChangeResult>(
        ConduitMethods.accountsSwitch,
        params: AccountRef.fromJson,
        result: AccountChangeResult.fromJson,
      );
  static const accountsRemove =
      ConduitMethodSpec<AccountRef, AccountChangeResult>(
        ConduitMethods.accountsRemove,
        params: AccountRef.fromJson,
        result: AccountChangeResult.fromJson,
      );
  static const accountsSignOut =
      ConduitMethodSpec<AccountSignOut, AccountChangeResult>(
        ConduitMethods.accountsSignOut,
        params: AccountSignOut.fromJson,
        result: AccountChangeResult.fromJson,
      );
  static const serversUpdate = ConduitMethodSpec<ServerDraft, ServerSummary>(
    ConduitMethods.serversUpdate,
    params: ServerDraft.fromJson,
    result: ServerSummary.fromJson,
  );
  static const serversStatus = ConduitMethodSpec<void, ServerStatus>(
    ConduitMethods.serversStatus,
    result: ServerStatus.fromJson,
  );
  static const authStatus = ConduitMethodSpec<void, AuthSnapshot>(
    ConduitMethods.authStatus,
    result: AuthSnapshot.fromJson,
  );
  static const authLoginWithPassword =
      ConduitMethodSpec<PasswordLogin, AuthSnapshot>(
        ConduitMethods.authLoginWithPassword,
        params: PasswordLogin.fromJson,
        result: AuthSnapshot.fromJson,
      );
  static const authLoginWithLdap =
      ConduitMethodSpec<PasswordLogin, AuthSnapshot>(
        ConduitMethods.authLoginWithLdap,
        params: PasswordLogin.fromJson,
        result: AuthSnapshot.fromJson,
      );
  static const authLoginWithApiKey =
      ConduitMethodSpec<ApiKeyLogin, AuthSnapshot>(
        ConduitMethods.authLoginWithApiKey,
        params: ApiKeyLogin.fromJson,
        result: AuthSnapshot.fromJson,
      );
  static const authSilentLogin = ConduitMethodSpec<void, AuthSnapshot>(
    ConduitMethods.authSilentLogin,
    result: AuthSnapshot.fromJson,
  );
  static const authCompleteExternal =
      ConduitMethodSpec<ExternalAuthCompletion, AuthSnapshot>(
        ConduitMethods.authCompleteExternal,
        params: ExternalAuthCompletion.fromJson,
        result: AuthSnapshot.fromJson,
      );
  static const authHasSavedCredentials =
      ConduitMethodSpec<void, SavedCredentialsResult>(
        ConduitMethods.authHasSavedCredentials,
        result: SavedCredentialsResult.fromJson,
      );
  static const authSetReviewerMode =
      ConduitMethodSpec<ReviewerMode, AuthSnapshot>(
        ConduitMethods.authSetReviewerMode,
        params: ReviewerMode.fromJson,
        result: AuthSnapshot.fromJson,
      );

  // settings.*

  static const settingsGetApp = ConduitMethodSpec<void, AppPreferences>(
    ConduitMethods.settingsGetApp,
    result: AppPreferences.fromJson,
  );
  static const settingsSetApp =
      ConduitMethodSpec<AppPreferencesPatch, AppPreferences>(
        ConduitMethods.settingsSetApp,
        params: AppPreferencesPatch.fromJson,
        result: AppPreferences.fromJson,
      );
  static const settingsGet = ConduitMethodSpec<void, AppSettingsDto>(
    ConduitMethods.settingsGet,
    result: AppSettingsDto.fromJson,
  );
  static const settingsSet =
      ConduitMethodSpec<AppSettingsPatch, AppSettingsDto>(
        ConduitMethods.settingsSet,
        params: AppSettingsPatch.fromJson,
        result: AppSettingsDto.fromJson,
      );
  static const settingsGetAccount = ConduitMethodSpec<void, AccountSettingsDto>(
    ConduitMethods.settingsGetAccount,
    result: AccountSettingsDto.fromJson,
  );
  static const settingsSetAccount =
      ConduitMethodSpec<AccountSettingsPatch, AccountSettingsDto>(
        ConduitMethods.settingsSetAccount,
        params: AccountSettingsPatch.fromJson,
        result: AccountSettingsDto.fromJson,
      );
  static const settingsModelPrompt =
      ConduitMethodSpec<ModelPromptRef, ModelPrompt>(
        ConduitMethods.settingsModelPrompt,
        params: ModelPromptRef.fromJson,
        result: ModelPrompt.fromJson,
      );
  static const settingsSetModelPrompt =
      ConduitMethodSpec<ModelPromptEdit, ModelPrompt>(
        ConduitMethods.settingsSetModelPrompt,
        params: ModelPromptEdit.fromJson,
        result: ModelPrompt.fromJson,
      );

  static const settingsQuickPills = ConduitMethodSpec<void, QuickPillOptions>(
    ConduitMethods.settingsQuickPills,
    result: QuickPillOptions.fromJson,
  );
  static const settingsVoiceProviders =
      ConduitMethodSpec<void, VoiceProviderOptions>(
        ConduitMethods.settingsVoiceProviders,
        result: VoiceProviderOptions.fromJson,
      );
  static const settingsAbout = ConduitMethodSpec<void, AboutInfo>(
    ConduitMethods.settingsAbout,
    result: AboutInfo.fromJson,
  );

  // profile.*

  static const profileGet = ConduitMethodSpec<void, ProfileDto>(
    ConduitMethods.profileGet,
    result: ProfileDto.fromJson,
  );
  static const profileUpdate = ConduitMethodSpec<ProfileEdit, ProfileDto>(
    ConduitMethods.profileUpdate,
    params: ProfileEdit.fromJson,
    result: ProfileDto.fromJson,
  );
  static const profileSetImage =
      ConduitMethodSpec<ProfileImageEdit, ProfileDto>(
        ConduitMethods.profileSetImage,
        params: ProfileImageEdit.fromJson,
        result: ProfileDto.fromJson,
      );
  static const profileRemoveImage = ConduitMethodSpec<void, ProfileDto>(
    ConduitMethods.profileRemoveImage,
    result: ProfileDto.fromJson,
  );
  static const profileChangePassword =
      ConduitMethodSpec<PasswordChange, PasswordChangeResult>(
        ConduitMethods.profileChangePassword,
        params: PasswordChange.fromJson,
        result: PasswordChangeResult.fromJson,
      );

  static const profileSignOutAll =
      ConduitMethodSpec<SignOutAll, AccountChangeResult>(
        ConduitMethods.profileSignOutAll,
        params: SignOutAll.fromJson,
        result: AccountChangeResult.fromJson,
      );

  // memories.*

  static const memoriesList = ConduitMethodSpec<void, MemoryList>(
    ConduitMethods.memoriesList,
    result: MemoryList.fromJson,
  );
  static const memoriesAdd = ConduitMethodSpec<MemoryEdit, MemoryList>(
    ConduitMethods.memoriesAdd,
    params: MemoryEdit.fromJson,
    result: MemoryList.fromJson,
  );
  static const memoriesUpdate = ConduitMethodSpec<MemoryEdit, MemoryList>(
    ConduitMethods.memoriesUpdate,
    params: MemoryEdit.fromJson,
    result: MemoryList.fromJson,
  );
  static const memoriesDelete = ConduitMethodSpec<MemoryRef, MemoryList>(
    ConduitMethods.memoriesDelete,
    params: MemoryRef.fromJson,
    result: MemoryList.fromJson,
  );
  static const memoriesClear = ConduitMethodSpec<void, MemoryList>(
    ConduitMethods.memoriesClear,
    result: MemoryList.fromJson,
  );
  static const memoriesSetEnabled = ConduitMethodSpec<MemoryToggle, MemoryList>(
    ConduitMethods.memoriesSetEnabled,
    params: MemoryToggle.fromJson,
    result: MemoryList.fromJson,
  );

  // releaseNotes.*

  static const releaseNotesCheck =
      ConduitMethodSpec<ReleaseNotesQuery, ReleaseNotesState>(
        ConduitMethods.releaseNotesCheck,
        params: ReleaseNotesQuery.fromJson,
        result: ReleaseNotesState.fromJson,
      );
  static const releaseNotesLatest =
      ConduitMethodSpec<ReleaseNotesQuery, ReleaseNotesState>(
        ConduitMethods.releaseNotesLatest,
        params: ReleaseNotesQuery.fromJson,
        result: ReleaseNotesState.fromJson,
      );
  static const releaseNotesDismiss = ConduitMethodSpec<void, OkResult>(
    ConduitMethods.releaseNotesDismiss,
    result: OkResult.fromJson,
  );

  // data.*

  static const dataSummary = ConduitMethodSpec<void, ChatDataSummary>(
    ConduitMethods.dataSummary,
    result: ChatDataSummary.fromJson,
  );
  static const dataExport =
      ConduitMethodSpec<DataExportRequest, DataActionResult>(
        ConduitMethods.dataExport,
        params: DataExportRequest.fromJson,
        result: DataActionResult.fromJson,
      );
  static const dataPreviewImport =
      ConduitMethodSpec<DataImportRequest, DataActionResult>(
        ConduitMethods.dataPreviewImport,
        params: DataImportRequest.fromJson,
        result: DataActionResult.fromJson,
      );
  static const dataSync = ConduitMethodSpec<void, ChatDataSummary>(
    ConduitMethods.dataSync,
    result: ChatDataSummary.fromJson,
  );
  static const dataImport =
      ConduitMethodSpec<DataImportRequest, DataActionResult>(
        ConduitMethods.dataImport,
        params: DataImportRequest.fromJson,
        result: DataActionResult.fromJson,
      );
  static const dataArchiveAll = ConduitMethodSpec<void, DataActionResult>(
    ConduitMethods.dataArchiveAll,
    result: DataActionResult.fromJson,
  );
  static const dataUnarchiveAll = ConduitMethodSpec<void, DataActionResult>(
    ConduitMethods.dataUnarchiveAll,
    result: DataActionResult.fromJson,
  );
  static const dataUnshareAll = ConduitMethodSpec<void, DataActionResult>(
    ConduitMethods.dataUnshareAll,
    result: DataActionResult.fromJson,
  );
  static const dataDeleteAll =
      ConduitMethodSpec<DataDeleteAll, DataActionResult>(
        ConduitMethods.dataDeleteAll,
        params: DataDeleteAll.fromJson,
        result: DataActionResult.fromJson,
      );
  static const dataConnection = ConduitMethodSpec<void, ConnectionHealth>(
    ConduitMethods.dataConnection,
    result: ConnectionHealth.fromJson,
  );

  // chats.*, sync.*

  static const chatsList = ConduitMethodSpec<void, ChatList>(
    ConduitMethods.chatsList,
    result: ChatList.fromJson,
  );
  static const chatsLoadMore = ConduitMethodSpec<void, ChatList>(
    ConduitMethods.chatsLoadMore,
    result: ChatList.fromJson,
  );
  static const chatsGet = ConduitMethodSpec<ChatRef, ChatResult>(
    ConduitMethods.chatsGet,
    params: ChatRef.fromJson,
    result: ChatResult.fromJson,
  );
  static const chatsSearch =
      ConduitMethodSpec<ChatSearchQuery, ChatSearchResults>(
        ConduitMethods.chatsSearch,
        params: ChatSearchQuery.fromJson,
        result: ChatSearchResults.fromJson,
      );
  static const chatsMove = ConduitMethodSpec<MoveChat, ChatList>(
    ConduitMethods.chatsMove,
    params: MoveChat.fromJson,
    result: ChatList.fromJson,
  );
  static const chatsFolder = ConduitMethodSpec<FolderRef, FolderContents>(
    ConduitMethods.chatsFolder,
    params: FolderRef.fromJson,
    result: FolderContents.fromJson,
  );
  static const chatsTree = ConduitMethodSpec<ChatRef, ChatTree>(
    ConduitMethods.chatsTree,
    params: ChatRef.fromJson,
    result: ChatTree.fromJson,
  );
  static const chatsSetCurrent = ConduitMethodSpec<ChatCurrent, ChatResult>(
    ConduitMethods.chatsSetCurrent,
    params: ChatCurrent.fromJson,
    result: ChatResult.fromJson,
  );
  static const chatsSetSystemPrompt =
      ConduitMethodSpec<ChatSystemPrompt, ChatResult>(
        ConduitMethods.chatsSetSystemPrompt,
        params: ChatSystemPrompt.fromJson,
        result: ChatResult.fromJson,
      );
  static const chatsBulk = ConduitMethodSpec<BulkChats, BulkChatsResult>(
    ConduitMethods.chatsBulk,
    params: BulkChats.fromJson,
    result: BulkChatsResult.fromJson,
  );
  static const chatsTagsAll = ConduitMethodSpec<void, TagList>(
    ConduitMethods.chatsTagsAll,
    result: TagList.fromJson,
  );
  static const chatsTagsAdd = ConduitMethodSpec<ChatTagEdit, TagList>(
    ConduitMethods.chatsTagsAdd,
    params: ChatTagEdit.fromJson,
    result: TagList.fromJson,
  );
  static const chatsTagsRemove = ConduitMethodSpec<ChatTagEdit, TagList>(
    ConduitMethods.chatsTagsRemove,
    params: ChatTagEdit.fromJson,
    result: TagList.fromJson,
  );
  static const chatsRename = ConduitMethodSpec<RenameChat, ChatList>(
    ConduitMethods.chatsRename,
    params: RenameChat.fromJson,
    result: ChatList.fromJson,
  );
  static const foldersCreate = ConduitMethodSpec<CreateFolder, FolderCreated>(
    ConduitMethods.foldersCreate,
    params: CreateFolder.fromJson,
    result: FolderCreated.fromJson,
  );
  static const foldersRename = ConduitMethodSpec<RenameFolder, ChatList>(
    ConduitMethods.foldersRename,
    params: RenameFolder.fromJson,
    result: ChatList.fromJson,
  );
  static const foldersDelete = ConduitMethodSpec<FolderRef, ChatList>(
    ConduitMethods.foldersDelete,
    params: FolderRef.fromJson,
    result: ChatList.fromJson,
  );
  static const foldersGet = ConduitMethodSpec<FolderRef, FolderSettings>(
    ConduitMethods.foldersGet,
    params: FolderRef.fromJson,
    result: FolderSettings.fromJson,
  );
  static const foldersUpdate = ConduitMethodSpec<FolderUpdate, FolderSettings>(
    ConduitMethods.foldersUpdate,
    params: FolderUpdate.fromJson,
    result: FolderSettings.fromJson,
  );
  static const foldersDraftModel =
      ConduitMethodSpec<FolderRef, FolderDraftModel>(
        ConduitMethods.foldersDraftModel,
        params: FolderRef.fromJson,
        result: FolderDraftModel.fromJson,
      );
  static const chatsSetPinned = ConduitMethodSpec<SetChatFlag, ChatList>(
    ConduitMethods.chatsSetPinned,
    params: SetChatFlag.fromJson,
    result: ChatList.fromJson,
  );
  static const chatsSetArchived = ConduitMethodSpec<SetChatFlag, ChatList>(
    ConduitMethods.chatsSetArchived,
    params: SetChatFlag.fromJson,
    result: ChatList.fromJson,
  );
  static const chatsDelete = ConduitMethodSpec<ChatRef, ChatList>(
    ConduitMethods.chatsDelete,
    params: ChatRef.fromJson,
    result: ChatList.fromJson,
  );
  static const syncGet = ConduitMethodSpec<void, SyncState>(
    ConduitMethods.syncGet,
    result: SyncState.fromJson,
  );
  static const chatsSetArchivedVisible =
      ConduitMethodSpec<ArchivedVisibility, ChatList>(
        ConduitMethods.chatsSetArchivedVisible,
        params: ArchivedVisibility.fromJson,
        result: ChatList.fromJson,
      );
  static const chatsShare = ConduitMethodSpec<ShareChat, ChatShare>(
    ConduitMethods.chatsShare,
    params: ShareChat.fromJson,
    result: ChatShare.fromJson,
  );
  static const chatsUnshare = ConduitMethodSpec<ChatRef, ChatShare>(
    ConduitMethods.chatsUnshare,
    params: ChatRef.fromJson,
    result: ChatShare.fromJson,
  );
  static const chatsFork = ConduitMethodSpec<ForkChat, ChatForked>(
    ConduitMethods.chatsFork,
    params: ForkChat.fromJson,
    result: ChatForked.fromJson,
  );
  static const chatsExport = ConduitMethodSpec<ExportChat, ChatExportFile>(
    ConduitMethods.chatsExport,
    params: ExportChat.fromJson,
    result: ChatExportFile.fromJson,
  );
  static const chatsGenerateTitle =
      ConduitMethodSpec<ChatRef, GeneratedTitle>(
        ConduitMethods.chatsGenerateTitle,
        params: ChatRef.fromJson,
        result: GeneratedTitle.fromJson,
      );
  static const chatsMarkUnread = ConduitMethodSpec<MarkUnread, ChatList>(
    ConduitMethods.chatsMarkUnread,
    params: MarkUnread.fromJson,
    result: ChatList.fromJson,
  );
  static const chatsSaveTemporary = ConduitMethodSpec<ChatRef, ChatForked>(
    ConduitMethods.chatsSaveTemporary,
    params: ChatRef.fromJson,
    result: ChatForked.fromJson,
  );

  // messages.*

  static const messagesDelete =
      ConduitMethodSpec<DeleteMessages, MessagesDeleted>(
        ConduitMethods.messagesDelete,
        params: DeleteMessages.fromJson,
        result: MessagesDeleted.fromJson,
      );

  // models.*, composer.*, prompts.*

  static const modelsList = ConduitMethodSpec<void, ModelList>(
    ConduitMethods.modelsList,
    result: ModelList.fromJson,
  );
  static const modelsSelect = ConduitMethodSpec<SelectModel, ModelList>(
    ConduitMethods.modelsSelect,
    params: SelectModel.fromJson,
    result: ModelList.fromJson,
  );
  static const modelsSetPinned = ConduitMethodSpec<SetModelPinned, ModelList>(
    ConduitMethods.modelsSetPinned,
    params: SetModelPinned.fromJson,
    result: ModelList.fromJson,
  );
  static const modelsOptions =
      ConduitMethodSpec<ModelOptionsQuery, ModelOptionsDto>(
        ConduitMethods.modelsOptions,
        params: ModelOptionsQuery.fromJson,
        result: ModelOptionsDto.fromJson,
      );
  static const modelsSetReasoningEffort =
      ConduitMethodSpec<SetReasoningEffort, ModelOptionsDto>(
        ConduitMethods.modelsSetReasoningEffort,
        params: SetReasoningEffort.fromJson,
        result: ModelOptionsDto.fromJson,
      );
  static const modelsSetFastTier =
      ConduitMethodSpec<SetFastTier, ModelOptionsDto>(
        ConduitMethods.modelsSetFastTier,
        params: SetFastTier.fromJson,
        result: ModelOptionsDto.fromJson,
      );

  // chatSettings.*, valves.*, access.*

  static const chatSettingsGet =
      ConduitMethodSpec<ChatSettingsQuery, ChatSettingsState>(
        ConduitMethods.chatSettingsGet,
        params: ChatSettingsQuery.fromJson,
        result: ChatSettingsState.fromJson,
      );
  static const chatSettingsCheck =
      ConduitMethodSpec<ChatSettingsEdit, ChatSettingsState>(
        ConduitMethods.chatSettingsCheck,
        params: ChatSettingsEdit.fromJson,
        result: ChatSettingsState.fromJson,
      );
  static const chatSettingsSave =
      ConduitMethodSpec<ChatSettingsEdit, ChatSettingsState>(
        ConduitMethods.chatSettingsSave,
        params: ChatSettingsEdit.fromJson,
        result: ChatSettingsState.fromJson,
      );
  static const valvesTargets =
      ConduitMethodSpec<ValveTargetsQuery, ValveTargets>(
        ConduitMethods.valvesTargets,
        params: ValveTargetsQuery.fromJson,
        result: ValveTargets.fromJson,
      );
  static const valvesGet = ConduitMethodSpec<ValvesRef, ValvesDocument>(
    ConduitMethods.valvesGet,
    params: ValvesRef.fromJson,
    result: ValvesDocument.fromJson,
  );
  static const valvesSave = ConduitMethodSpec<ValvesSave, ValvesDocument>(
    ConduitMethods.valvesSave,
    params: ValvesSave.fromJson,
    result: ValvesDocument.fromJson,
  );
  static const accessGet = ConduitMethodSpec<AccessRef, AccessState>(
    ConduitMethods.accessGet,
    params: AccessRef.fromJson,
    result: AccessState.fromJson,
  );
  static const accessSet = ConduitMethodSpec<AccessEdit, AccessState>(
    ConduitMethods.accessSet,
    params: AccessEdit.fromJson,
    result: AccessState.fromJson,
  );
  static const accessPrincipals =
      ConduitMethodSpec<AccessPrincipalQuery, AccessPrincipals>(
        ConduitMethods.accessPrincipals,
        params: AccessPrincipalQuery.fromJson,
        result: AccessPrincipals.fromJson,
      );
  static const composerOptions = ConduitMethodSpec<void, ComposerOptions>(
    ConduitMethods.composerOptions,
    result: ComposerOptions.fromJson,
  );
  static const composerKnowledge =
      ConduitMethodSpec<KnowledgeQuery, KnowledgeList>(
        ConduitMethods.composerKnowledge,
        params: KnowledgeQuery.fromJson,
        result: KnowledgeList.fromJson,
      );
  // drafts.*, queue.*, mentions.*, skills.*, context.*, files.*

  static const draftsGet = ConduitMethodSpec<DraftRef, Draft>(
    ConduitMethods.draftsGet,
    params: DraftRef.fromJson,
    result: Draft.fromJson,
  );
  static const draftsSave = ConduitMethodSpec<DraftSave, Draft>(
    ConduitMethods.draftsSave,
    params: DraftSave.fromJson,
    result: Draft.fromJson,
  );
  static const queueGet = ConduitMethodSpec<ChatRef, QueueState>(
    ConduitMethods.queueGet,
    params: ChatRef.fromJson,
    result: QueueState.fromJson,
  );
  static const queueAdd = ConduitMethodSpec<QueueAdd, QueueState>(
    ConduitMethods.queueAdd,
    params: QueueAdd.fromJson,
    result: QueueState.fromJson,
  );
  static const queueEdit = ConduitMethodSpec<QueueEdit, QueueState>(
    ConduitMethods.queueEdit,
    params: QueueEdit.fromJson,
    result: QueueState.fromJson,
  );
  static const queueRemove = ConduitMethodSpec<QueueDraftRef, QueueState>(
    ConduitMethods.queueRemove,
    params: QueueDraftRef.fromJson,
    result: QueueState.fromJson,
  );
  static const queueSendNow =
      ConduitMethodSpec<QueueDraftRef, QueueSendNowResult>(
        ConduitMethods.queueSendNow,
        params: QueueDraftRef.fromJson,
        result: QueueSendNowResult.fromJson,
      );
  static const queueRetry = ConduitMethodSpec<ChatRef, QueueState>(
    ConduitMethods.queueRetry,
    params: ChatRef.fromJson,
    result: QueueState.fromJson,
  );
  static const mentionsSearch = ConduitMethodSpec<ComposerSearch, MentionList>(
    ConduitMethods.mentionsSearch,
    params: ComposerSearch.fromJson,
    result: MentionList.fromJson,
  );
  static const skillsSearch = ConduitMethodSpec<ComposerSearch, SkillList>(
    ConduitMethods.skillsSearch,
    params: ComposerSearch.fromJson,
    result: SkillList.fromJson,
  );
  static const contextSearch =
      ConduitMethodSpec<ComposerSearch, ContextSuggestions>(
        ConduitMethods.contextSearch,
        params: ComposerSearch.fromJson,
        result: ContextSuggestions.fromJson,
      );
  static const contextFetchUrl = ConduitMethodSpec<FetchUrl, FetchedUrl>(
    ConduitMethods.contextFetchUrl,
    params: FetchUrl.fromJson,
    result: FetchedUrl.fromJson,
  );
  static const filesList = ConduitMethodSpec<ComposerSearch, ServerFileList>(
    ConduitMethods.filesList,
    params: ComposerSearch.fromJson,
    result: ServerFileList.fromJson,
  );

  static const promptsList = ConduitMethodSpec<void, PromptList>(
    ConduitMethods.promptsList,
    result: PromptList.fromJson,
  );
  static const promptsRender = ConduitMethodSpec<RenderPrompt, RenderedPrompt>(
    ConduitMethods.promptsRender,
    params: RenderPrompt.fromJson,
    result: RenderedPrompt.fromJson,
  );

  // direct.*

  static const directList = ConduitMethodSpec<void, DirectConnectionList>(
    ConduitMethods.directList,
    result: DirectConnectionList.fromJson,
  );
  static const directSave =
      ConduitMethodSpec<DirectConnectionEdit, DirectConnectionList>(
        ConduitMethods.directSave,
        params: DirectConnectionEdit.fromJson,
        result: DirectConnectionList.fromJson,
      );
  static const directRemove =
      ConduitMethodSpec<DirectRef, DirectConnectionList>(
        ConduitMethods.directRemove,
        params: DirectRef.fromJson,
        result: DirectConnectionList.fromJson,
      );
  static const directSetEnabled =
      ConduitMethodSpec<DirectEnable, DirectConnectionList>(
        ConduitMethods.directSetEnabled,
        params: DirectEnable.fromJson,
        result: DirectConnectionList.fromJson,
      );
  static const directTest =
      ConduitMethodSpec<DirectConnectionEdit, DirectTestResult>(
        ConduitMethods.directTest,
        params: DirectConnectionEdit.fromJson,
        result: DirectTestResult.fromJson,
      );
  static const directSetHistory =
      ConduitMethodSpec<DirectHistory, DirectConnectionList>(
        ConduitMethods.directSetHistory,
        params: DirectHistory.fromJson,
        result: DirectConnectionList.fromJson,
      );
  static const directSetPreferred =
      ConduitMethodSpec<DirectPreferred, DirectConnectionList>(
        ConduitMethods.directSetPreferred,
        params: DirectPreferred.fromJson,
        result: DirectConnectionList.fromJson,
      );
  static const directOllamaModels =
      ConduitMethodSpec<DirectRef, OllamaModelList>(
        ConduitMethods.directOllamaModels,
        params: DirectRef.fromJson,
        result: OllamaModelList.fromJson,
      );
  static const directOllamaLoad =
      ConduitMethodSpec<OllamaModelAction, OllamaModelList>(
        ConduitMethods.directOllamaLoad,
        params: OllamaModelAction.fromJson,
        result: OllamaModelList.fromJson,
      );
  static const directOllamaUnload =
      ConduitMethodSpec<OllamaModelAction, OllamaModelList>(
        ConduitMethods.directOllamaUnload,
        params: OllamaModelAction.fromJson,
        result: OllamaModelList.fromJson,
      );
  static const directOllamaKeepAlive =
      ConduitMethodSpec<OllamaModelAction, OllamaModelList>(
        ConduitMethods.directOllamaKeepAlive,
        params: OllamaModelAction.fromJson,
        result: OllamaModelList.fromJson,
      );
  static const directOllamaThinking =
      ConduitMethodSpec<OllamaModelAction, OllamaModelList>(
        ConduitMethods.directOllamaThinking,
        params: OllamaModelAction.fromJson,
        result: OllamaModelList.fromJson,
      );

  // mcp.*

  static const mcpList = ConduitMethodSpec<void, McpServerList>(
    ConduitMethods.mcpList,
    result: McpServerList.fromJson,
  );
  static const mcpSave = ConduitMethodSpec<McpServerEdit, McpServerList>(
    ConduitMethods.mcpSave,
    params: McpServerEdit.fromJson,
    result: McpServerList.fromJson,
  );
  static const mcpRemove = ConduitMethodSpec<McpRef, McpServerList>(
    ConduitMethods.mcpRemove,
    params: McpRef.fromJson,
    result: McpServerList.fromJson,
  );
  static const mcpSetEnabled = ConduitMethodSpec<McpEnable, McpServerList>(
    ConduitMethods.mcpSetEnabled,
    params: McpEnable.fromJson,
    result: McpServerList.fromJson,
  );
  static const mcpTest = ConduitMethodSpec<McpServerEdit, McpTestResult>(
    ConduitMethods.mcpTest,
    params: McpServerEdit.fromJson,
    result: McpTestResult.fromJson,
  );
  static const mcpConnect = ConduitMethodSpec<McpRef, McpServerList>(
    ConduitMethods.mcpConnect,
    params: McpRef.fromJson,
    result: McpServerList.fromJson,
  );
  static const mcpCancelConnect = ConduitMethodSpec<McpRef, CancelledResult>(
    ConduitMethods.mcpCancelConnect,
    params: McpRef.fromJson,
    result: CancelledResult.fromJson,
  );
  static const mcpDisconnect = ConduitMethodSpec<McpRef, McpServerList>(
    ConduitMethods.mcpDisconnect,
    params: McpRef.fromJson,
    result: McpServerList.fromJson,
  );
  static const mcpForgetApproval =
      ConduitMethodSpec<McpForgetApproval, McpServerList>(
        ConduitMethods.mcpForgetApproval,
        params: McpForgetApproval.fromJson,
        result: McpServerList.fromJson,
      );
  static const mcpContent = ConduitMethodSpec<McpRef, McpContent>(
    ConduitMethods.mcpContent,
    params: McpRef.fromJson,
    result: McpContent.fromJson,
  );
  static const mcpGetPrompt =
      ConduitMethodSpec<McpGetPrompt, McpContentPreview>(
        ConduitMethods.mcpGetPrompt,
        params: McpGetPrompt.fromJson,
        result: McpContentPreview.fromJson,
      );
  static const mcpReadResource =
      ConduitMethodSpec<McpReadResource, McpContentPreview>(
        ConduitMethods.mcpReadResource,
        params: McpReadResource.fromJson,
        result: McpContentPreview.fromJson,
      );

  // turns.*

  static const turnsSend = ConduitMethodSpec<SendTurn, SendTurnAccepted>(
    ConduitMethods.turnsSend,
    params: SendTurn.fromJson,
    result: SendTurnAccepted.fromJson,
  );
  static const turnsStop = ConduitMethodSpec<StopTurn, StoppedResult>(
    ConduitMethods.turnsStop,
    params: StopTurn.fromJson,
    result: StoppedResult.fromJson,
  );
  static const turnsRegenerate =
      ConduitMethodSpec<RegenerateTurn, SendTurnAccepted>(
        ConduitMethods.turnsRegenerate,
        params: RegenerateTurn.fromJson,
        result: SendTurnAccepted.fromJson,
      );
  static const turnsEdit = ConduitMethodSpec<EditTurn, SendTurnAccepted>(
    ConduitMethods.turnsEdit,
    params: EditTurn.fromJson,
    result: SendTurnAccepted.fromJson,
  );
  static const turnsSteer = ConduitMethodSpec<SteerTurn, SteerResult>(
    ConduitMethods.turnsSteer,
    params: SteerTurn.fromJson,
    result: SteerResult.fromJson,
  );
  static const turnsRate = ConduitMethodSpec<RateTurn, RatedResult>(
    ConduitMethods.turnsRate,
    params: RateTurn.fromJson,
    result: RatedResult.fromJson,
  );
  static const turnsMerge = ConduitMethodSpec<MergeTurn, MergeStarted>(
    ConduitMethods.turnsMerge,
    params: MergeTurn.fromJson,
    result: MergeStarted.fromJson,
  );

  // handoff.*

  static const handoffAnswer =
      ConduitMethodSpec<HandoffAnswer, HandoffAnswered>(
        ConduitMethods.handoffAnswer,
        params: HandoffAnswer.fromJson,
        result: HandoffAnswered.fromJson,
      );
  static const turnsRetryQueued = ConduitMethodSpec<QueuedTurnRef, OkResult>(
    ConduitMethods.turnsRetryQueued,
    params: QueuedTurnRef.fromJson,
    result: OkResult.fromJson,
  );
  static const turnsRemoveQueued = ConduitMethodSpec<QueuedTurnRef, OkResult>(
    ConduitMethods.turnsRemoveQueued,
    params: QueuedTurnRef.fromJson,
    result: OkResult.fromJson,
  );

  // chatPrompts.*

  static const chatPromptsGet =
      ConduitMethodSpec<ChatPromptRef, ChatPromptState>(
        ConduitMethods.chatPromptsGet,
        params: ChatPromptRef.fromJson,
        result: ChatPromptState.fromJson,
      );
  static const chatPromptsAnswer =
      ConduitMethodSpec<ChatPromptAnswer, AcceptedResult>(
        ConduitMethods.chatPromptsAnswer,
        params: ChatPromptAnswer.fromJson,
        result: AcceptedResult.fromJson,
      );
  static const chatPromptsDecide =
      ConduitMethodSpec<ChatPromptDecision, AcceptedResult>(
        ConduitMethods.chatPromptsDecide,
        params: ChatPromptDecision.fromJson,
        result: AcceptedResult.fromJson,
      );

  // mcpApps.*

  static const mcpAppsOpen = ConduitMethodSpec<McpAppOpen, McpAppSession>(
    ConduitMethods.mcpAppsOpen,
    params: McpAppOpen.fromJson,
    result: McpAppSession.fromJson,
  );
  static const mcpAppsMessage = ConduitMethodSpec<McpAppMessage, OkResult>(
    ConduitMethods.mcpAppsMessage,
    params: McpAppMessage.fromJson,
    result: OkResult.fromJson,
  );
  static const mcpAppsContext = ConduitMethodSpec<McpAppContext, OkResult>(
    ConduitMethods.mcpAppsContext,
    params: McpAppContext.fromJson,
    result: OkResult.fromJson,
  );
  static const mcpAppsClose = ConduitMethodSpec<McpAppRef, OkResult>(
    ConduitMethods.mcpAppsClose,
    params: McpAppRef.fromJson,
    result: OkResult.fromJson,
  );

  // notes.*

  static const notesList = ConduitMethodSpec<NoteQuery, NoteList>(
    ConduitMethods.notesList,
    params: NoteQuery.fromJson,
    result: NoteList.fromJson,
  );
  static const notesGet = ConduitMethodSpec<NoteRef, NoteResult>(
    ConduitMethods.notesGet,
    params: NoteRef.fromJson,
    result: NoteResult.fromJson,
  );
  static const notesSave = ConduitMethodSpec<NoteSave, NoteDetail>(
    ConduitMethods.notesSave,
    params: NoteSave.fromJson,
    result: NoteDetail.fromJson,
  );
  static const notesDelete = ConduitMethodSpec<NoteRef, DeletedResult>(
    ConduitMethods.notesDelete,
    params: NoteRef.fromJson,
    result: DeletedResult.fromJson,
  );
  static const notesSetPinned = ConduitMethodSpec<NotePin, NoteSummary>(
    ConduitMethods.notesSetPinned,
    params: NotePin.fromJson,
    result: NoteSummary.fromJson,
  );
  static const notesGenerateTitle = ConduitMethodSpec<NoteAi, NoteTitle>(
    ConduitMethods.notesGenerateTitle,
    params: NoteAi.fromJson,
    result: NoteTitle.fromJson,
  );
  static const notesEnhance = ConduitMethodSpec<NoteAi, NoteBody>(
    ConduitMethods.notesEnhance,
    params: NoteAi.fromJson,
    result: NoteBody.fromJson,
  );
  static const notesAttach = ConduitMethodSpec<NoteAttach, NoteDetail>(
    ConduitMethods.notesAttach,
    params: NoteAttach.fromJson,
    result: NoteDetail.fromJson,
  );
  static const notesDetach = ConduitMethodSpec<NoteDetach, NoteDetail>(
    ConduitMethods.notesDetach,
    params: NoteDetach.fromJson,
    result: NoteDetail.fromJson,
  );

  // channels.*

  static const channelsList = ConduitMethodSpec<void, ChannelList>(
    ConduitMethods.channelsList,
    result: ChannelList.fromJson,
  );
  static const channelsSave = ConduitMethodSpec<ChannelEdit, ChannelList>(
    ConduitMethods.channelsSave,
    params: ChannelEdit.fromJson,
    result: ChannelList.fromJson,
  );
  static const channelsDelete = ConduitMethodSpec<ChannelRef, ChannelList>(
    ConduitMethods.channelsDelete,
    params: ChannelRef.fromJson,
    result: ChannelList.fromJson,
  );
  static const channelsLeave = ConduitMethodSpec<ChannelRef, ChannelList>(
    ConduitMethods.channelsLeave,
    params: ChannelRef.fromJson,
    result: ChannelList.fromJson,
  );
  static const channelsMessages =
      ConduitMethodSpec<ChannelMessagesQuery, ChannelMessages>(
        ConduitMethods.channelsMessages,
        params: ChannelMessagesQuery.fromJson,
        result: ChannelMessages.fromJson,
      );
  static const channelsPost = ConduitMethodSpec<ChannelPost, ChannelMessageDto>(
    ConduitMethods.channelsPost,
    params: ChannelPost.fromJson,
    result: ChannelMessageDto.fromJson,
  );
  static const channelsEditMessage =
      ConduitMethodSpec<ChannelMessageEdit, ChannelMessageDto>(
        ConduitMethods.channelsEditMessage,
        params: ChannelMessageEdit.fromJson,
        result: ChannelMessageDto.fromJson,
      );
  static const channelsDeleteMessage =
      ConduitMethodSpec<ChannelMessageRef, OkResult>(
        ConduitMethods.channelsDeleteMessage,
        params: ChannelMessageRef.fromJson,
        result: OkResult.fromJson,
      );
  static const channelsReact = ConduitMethodSpec<ChannelReact, OkResult>(
    ConduitMethods.channelsReact,
    params: ChannelReact.fromJson,
    result: OkResult.fromJson,
  );
  static const channelsPin = ConduitMethodSpec<ChannelPin, OkResult>(
    ConduitMethods.channelsPin,
    params: ChannelPin.fromJson,
    result: OkResult.fromJson,
  );
  static const channelsTyping = ConduitMethodSpec<ChannelTyping, OkResult>(
    ConduitMethods.channelsTyping,
    params: ChannelTyping.fromJson,
    result: OkResult.fromJson,
  );
  static const channelsMarkRead = ConduitMethodSpec<ChannelRef, OkResult>(
    ConduitMethods.channelsMarkRead,
    params: ChannelRef.fromJson,
    result: OkResult.fromJson,
  );
  static const channelsMembers = ConduitMethodSpec<ChannelRef, ChannelMembers>(
    ConduitMethods.channelsMembers,
    params: ChannelRef.fromJson,
    result: ChannelMembers.fromJson,
  );

  // workspace.*

  static const workspaceCapabilities = ConduitMethodSpec<void, WorkspaceAccess>(
    ConduitMethods.workspaceCapabilities,
    result: WorkspaceAccess.fromJson,
  );
  static const workspaceList = ConduitMethodSpec<WorkspaceQuery, WorkspacePage>(
    ConduitMethods.workspaceList,
    params: WorkspaceQuery.fromJson,
    result: WorkspacePage.fromJson,
  );
  static const workspaceGet = ConduitMethodSpec<WorkspaceRef, WorkspaceDetail>(
    ConduitMethods.workspaceGet,
    params: WorkspaceRef.fromJson,
    result: WorkspaceDetail.fromJson,
  );
  static const workspaceSave =
      ConduitMethodSpec<WorkspaceSave, WorkspaceDetail>(
        ConduitMethods.workspaceSave,
        params: WorkspaceSave.fromJson,
        result: WorkspaceDetail.fromJson,
      );
  static const workspaceDelete = ConduitMethodSpec<WorkspaceRef, OkResult>(
    ConduitMethods.workspaceDelete,
    params: WorkspaceRef.fromJson,
    result: OkResult.fromJson,
  );
  static const workspaceToggle = ConduitMethodSpec<WorkspaceRef, WorkspaceItem>(
    ConduitMethods.workspaceToggle,
    params: WorkspaceRef.fromJson,
    result: WorkspaceItem.fromJson,
  );
  static const workspaceSetAccess =
      ConduitMethodSpec<WorkspaceAccessEdit, WorkspaceDetail>(
        ConduitMethods.workspaceSetAccess,
        params: WorkspaceAccessEdit.fromJson,
        result: WorkspaceDetail.fromJson,
      );
  static const workspacePrincipals =
      ConduitMethodSpec<WorkspacePrincipalQuery, WorkspacePrincipals>(
        ConduitMethods.workspacePrincipals,
        params: WorkspacePrincipalQuery.fromJson,
        result: WorkspacePrincipals.fromJson,
      );
  static const workspaceExport =
      ConduitMethodSpec<WorkspaceExportQuery, WorkspaceExportFile>(
        ConduitMethods.workspaceExport,
        params: WorkspaceExportQuery.fromJson,
        result: WorkspaceExportFile.fromJson,
      );
  static const workspaceImport =
      ConduitMethodSpec<WorkspaceImport, WorkspaceImportResult>(
        ConduitMethods.workspaceImport,
        params: WorkspaceImport.fromJson,
        result: WorkspaceImportResult.fromJson,
      );
  static const workspaceModelOptions =
      ConduitMethodSpec<void, WorkspaceModelOptions>(
        ConduitMethods.workspaceModelOptions,
        result: WorkspaceModelOptions.fromJson,
      );
  static const workspacePromptHistory =
      ConduitMethodSpec<WorkspaceRef, WorkspacePromptHistory>(
        ConduitMethods.workspacePromptHistory,
        params: WorkspaceRef.fromJson,
        result: WorkspacePromptHistory.fromJson,
      );
  static const workspacePromptDiff =
      ConduitMethodSpec<WorkspacePromptDiffQuery, WorkspacePromptDiff>(
        ConduitMethods.workspacePromptDiff,
        params: WorkspacePromptDiffQuery.fromJson,
        result: WorkspacePromptDiff.fromJson,
      );
  static const workspacePromptSetVersion =
      ConduitMethodSpec<WorkspacePromptVersionRef, WorkspaceDetail>(
        ConduitMethods.workspacePromptSetVersion,
        params: WorkspacePromptVersionRef.fromJson,
        result: WorkspaceDetail.fromJson,
      );
  static const workspacePromptDeleteVersion =
      ConduitMethodSpec<WorkspacePromptVersionRef, OkResult>(
        ConduitMethods.workspacePromptDeleteVersion,
        params: WorkspacePromptVersionRef.fromJson,
        result: OkResult.fromJson,
      );
  static const workspaceValves =
      ConduitMethodSpec<WorkspaceValvesQuery, WorkspaceValves>(
        ConduitMethods.workspaceValves,
        params: WorkspaceValvesQuery.fromJson,
        result: WorkspaceValves.fromJson,
      );
  static const workspaceSaveValves =
      ConduitMethodSpec<WorkspaceValves, WorkspaceValves>(
        ConduitMethods.workspaceSaveValves,
        params: WorkspaceValves.fromJson,
        result: WorkspaceValves.fromJson,
      );
  static const workspaceToolFromUrl =
      ConduitMethodSpec<WorkspaceUrl, WorkspaceToolDto>(
        ConduitMethods.workspaceToolFromUrl,
        params: WorkspaceUrl.fromJson,
        result: WorkspaceToolDto.fromJson,
      );
  static const workspaceFiles =
      ConduitMethodSpec<WorkspaceFilesQuery, WorkspaceFiles>(
        ConduitMethods.workspaceFiles,
        params: WorkspaceFilesQuery.fromJson,
        result: WorkspaceFiles.fromJson,
      );
  static const workspaceAttachFiles =
      ConduitMethodSpec<WorkspaceFilesAttach, WorkspaceFiles>(
        ConduitMethods.workspaceAttachFiles,
        params: WorkspaceFilesAttach.fromJson,
        result: WorkspaceFiles.fromJson,
      );
  static const workspaceFileAction =
      ConduitMethodSpec<WorkspaceFileAction, WorkspaceFiles>(
        ConduitMethods.workspaceFileAction,
        params: WorkspaceFileAction.fromJson,
        result: WorkspaceFiles.fromJson,
      );
  static const workspaceDirectoryAction =
      ConduitMethodSpec<WorkspaceDirectoryAction, WorkspaceFiles>(
        ConduitMethods.workspaceDirectoryAction,
        params: WorkspaceDirectoryAction.fromJson,
        result: WorkspaceFiles.fromJson,
      );
  static const workspaceKnowledgeReset =
      ConduitMethodSpec<WorkspaceRef, WorkspaceDetail>(
        ConduitMethods.workspaceKnowledgeReset,
        params: WorkspaceRef.fromJson,
        result: WorkspaceDetail.fromJson,
      );
  static const workspaceKnowledgeCleanup =
      ConduitMethodSpec<WorkspaceRef, WorkspaceFiles>(
        ConduitMethods.workspaceKnowledgeCleanup,
        params: WorkspaceRef.fromJson,
        result: WorkspaceFiles.fromJson,
      );

  // hermes.*

  static const hermesSettings = ConduitMethodSpec<void, HermesSettings>(
    ConduitMethods.hermesSettings,
    result: HermesSettings.fromJson,
  );
  static const hermesSaveSettings =
      ConduitMethodSpec<HermesSettingsEdit, HermesSettings>(
        ConduitMethods.hermesSaveSettings,
        params: HermesSettingsEdit.fromJson,
        result: HermesSettings.fromJson,
      );
  static const hermesTest =
      ConduitMethodSpec<HermesSettingsEdit, HermesTestResult>(
        ConduitMethods.hermesTest,
        params: HermesSettingsEdit.fromJson,
        result: HermesTestResult.fromJson,
      );
  static const hermesStatus = ConduitMethodSpec<void, HermesStatus>(
    ConduitMethods.hermesStatus,
    result: HermesStatus.fromJson,
  );
  static const hermesSignIn = ConduitMethodSpec<void, HermesSettings>(
    ConduitMethods.hermesSignIn,
    result: HermesSettings.fromJson,
  );
  static const hermesSignOut = ConduitMethodSpec<void, HermesSettings>(
    ConduitMethods.hermesSignOut,
    result: HermesSettings.fromJson,
  );
  static const hermesSessions = ConduitMethodSpec<void, HermesSessions>(
    ConduitMethods.hermesSessions,
    result: HermesSessions.fromJson,
  );
  static const hermesRenameSession =
      ConduitMethodSpec<HermesRename, HermesSessions>(
        ConduitMethods.hermesRenameSession,
        params: HermesRename.fromJson,
        result: HermesSessions.fromJson,
      );
  static const hermesDeleteSession =
      ConduitMethodSpec<HermesRef, HermesSessions>(
        ConduitMethods.hermesDeleteSession,
        params: HermesRef.fromJson,
        result: HermesSessions.fromJson,
      );
  static const hermesForkSession =
      ConduitMethodSpec<HermesRef, HermesSessionDto>(
        ConduitMethods.hermesForkSession,
        params: HermesRef.fromJson,
        result: HermesSessionDto.fromJson,
      );
  static const hermesJobs = ConduitMethodSpec<void, HermesJobs>(
    ConduitMethods.hermesJobs,
    result: HermesJobs.fromJson,
  );
  static const hermesSaveJob = ConduitMethodSpec<HermesJobEdit, HermesJobs>(
    ConduitMethods.hermesSaveJob,
    params: HermesJobEdit.fromJson,
    result: HermesJobs.fromJson,
  );
  static const hermesSetJobEnabled =
      ConduitMethodSpec<HermesJobToggle, HermesJobs>(
        ConduitMethods.hermesSetJobEnabled,
        params: HermesJobToggle.fromJson,
        result: HermesJobs.fromJson,
      );
  static const hermesRunJob = ConduitMethodSpec<HermesRef, HermesJobs>(
    ConduitMethods.hermesRunJob,
    params: HermesRef.fromJson,
    result: HermesJobs.fromJson,
  );
  static const hermesDeleteJob = ConduitMethodSpec<HermesRef, HermesJobs>(
    ConduitMethods.hermesDeleteJob,
    params: HermesRef.fromJson,
    result: HermesJobs.fromJson,
  );
  static const hermesCatalog = ConduitMethodSpec<void, HermesCatalog>(
    ConduitMethods.hermesCatalog,
    result: HermesCatalog.fromJson,
  );

  // terminal.*

  static const terminalServers =
      ConduitMethodSpec<TerminalScope, TerminalServers>(
        ConduitMethods.terminalServers,
        params: TerminalScope.fromJson,
        result: TerminalServers.fromJson,
      );
  static const terminalSelect =
      ConduitMethodSpec<TerminalSelect, TerminalServers>(
        ConduitMethods.terminalSelect,
        params: TerminalSelect.fromJson,
        result: TerminalServers.fromJson,
      );
  static const terminalAttach =
      ConduitMethodSpec<TerminalAttach, TerminalAttached>(
        ConduitMethods.terminalAttach,
        params: TerminalAttach.fromJson,
        result: TerminalAttached.fromJson,
      );
  static const terminalList = ConduitMethodSpec<TerminalPath, TerminalListing>(
    ConduitMethods.terminalList,
    params: TerminalPath.fromJson,
    result: TerminalListing.fromJson,
  );
  static const terminalRead =
      ConduitMethodSpec<TerminalPath, TerminalFileContent>(
        ConduitMethods.terminalRead,
        params: TerminalPath.fromJson,
        result: TerminalFileContent.fromJson,
      );
  static const terminalDownload =
      ConduitMethodSpec<TerminalPath, TerminalFileContent>(
        ConduitMethods.terminalDownload,
        params: TerminalPath.fromJson,
        result: TerminalFileContent.fromJson,
      );
  static const terminalFileAction =
      ConduitMethodSpec<TerminalFileAction, OkResult>(
        ConduitMethods.terminalFileAction,
        params: TerminalFileAction.fromJson,
        result: OkResult.fromJson,
      );
  static const terminalPorts =
      ConduitMethodSpec<TerminalHandleRef, TerminalPorts>(
        ConduitMethods.terminalPorts,
        params: TerminalHandleRef.fromJson,
        result: TerminalPorts.fromJson,
      );
  static const terminalPreviewPort =
      ConduitMethodSpec<TerminalPortRef, TerminalPreview>(
        ConduitMethods.terminalPreviewPort,
        params: TerminalPortRef.fromJson,
        result: TerminalPreview.fromJson,
      );

  // voice.*

  static const voiceSettings = ConduitMethodSpec<void, VoiceSettings>(
    ConduitMethods.voiceSettings,
    result: VoiceSettings.fromJson,
  );
  static const voiceSaveSettings =
      ConduitMethodSpec<VoiceSettingsEdit, VoiceSettings>(
        ConduitMethods.voiceSaveSettings,
        params: VoiceSettingsEdit.fromJson,
        result: VoiceSettings.fromJson,
      );
  static const voiceVoices = ConduitMethodSpec<void, VoiceVoices>(
    ConduitMethods.voiceVoices,
    result: VoiceVoices.fromJson,
  );
  static const voiceSpeak = ConduitMethodSpec<VoiceSpeak, VoiceSpeech>(
    ConduitMethods.voiceSpeak,
    params: VoiceSpeak.fromJson,
    result: VoiceSpeech.fromJson,
  );
  static const voiceModels = ConduitMethodSpec<void, VoiceModels>(
    ConduitMethods.voiceModels,
    result: VoiceModels.fromJson,
  );
  static const voiceDownloadModel =
      ConduitMethodSpec<VoiceModelRef, VoiceModels>(
        ConduitMethods.voiceDownloadModel,
        params: VoiceModelRef.fromJson,
        result: VoiceModels.fromJson,
      );
  static const voiceDeleteModel = ConduitMethodSpec<VoiceModelRef, VoiceModels>(
    ConduitMethods.voiceDeleteModel,
    params: VoiceModelRef.fromJson,
    result: VoiceModels.fromJson,
  );

  /// Every method, once.
  static const List<ConduitMethodSpec<Object?, Object?>> all =
      <ConduitMethodSpec<Object?, Object?>>[
        systemHandshake,
        systemPing,
        systemCapabilities,
        systemShutdown,
        systemExportDiagnostics,
        systemNetwork,
        eventsSubscribe,
        uiRespond,
        accountsList,
        accountsAdd,
        accountsCancelAdd,
        accountsSwitch,
        accountsRemove,
        accountsSignOut,
        serversUpdate,
        serversStatus,
        authStatus,
        authLoginWithPassword,
        authLoginWithLdap,
        authLoginWithApiKey,
        authSilentLogin,
        authCompleteExternal,
        authHasSavedCredentials,
        authSetReviewerMode,
        settingsGetApp,
        settingsSetApp,
        settingsGet,
        settingsSet,
        settingsGetAccount,
        settingsSetAccount,
        settingsModelPrompt,
        settingsSetModelPrompt,
        settingsQuickPills,
        settingsVoiceProviders,
        settingsAbout,
        profileGet,
        profileUpdate,
        profileSetImage,
        profileRemoveImage,
        profileChangePassword,
        profileSignOutAll,
        memoriesList,
        memoriesAdd,
        memoriesUpdate,
        memoriesDelete,
        memoriesClear,
        memoriesSetEnabled,
        releaseNotesCheck,
        releaseNotesLatest,
        releaseNotesDismiss,
        dataSummary,
        dataExport,
        dataPreviewImport,
        dataImport,
        dataSync,
        dataArchiveAll,
        dataUnarchiveAll,
        dataUnshareAll,
        dataDeleteAll,
        dataConnection,
        chatsList,
        chatsLoadMore,
        chatsGet,
        chatsSearch,
        chatsMove,
        chatsFolder,
        chatsTree,
        chatsSetCurrent,
        chatsSetSystemPrompt,
        chatsBulk,
        chatsTagsAll,
        chatsTagsAdd,
        chatsTagsRemove,
        chatsRename,
        foldersCreate,
        foldersRename,
        foldersDelete,
        foldersGet,
        foldersUpdate,
        foldersDraftModel,
        chatsSetPinned,
        chatsSetArchived,
        chatsDelete,
        syncGet,
        chatsSetArchivedVisible,
        chatsShare,
        chatsUnshare,
        chatsFork,
        chatsExport,
        chatsGenerateTitle,
        chatsMarkUnread,
        chatsSaveTemporary,
        messagesDelete,
        modelsList,
        modelsSelect,
        modelsSetPinned,
        modelsOptions,
        modelsSetReasoningEffort,
        modelsSetFastTier,
        chatSettingsGet,
        chatSettingsCheck,
        chatSettingsSave,
        valvesTargets,
        valvesGet,
        valvesSave,
        accessGet,
        accessSet,
        accessPrincipals,
        composerOptions,
        composerKnowledge,
        draftsGet,
        draftsSave,
        queueGet,
        queueAdd,
        queueEdit,
        queueRemove,
        queueSendNow,
        queueRetry,
        mentionsSearch,
        skillsSearch,
        contextSearch,
        contextFetchUrl,
        filesList,
        promptsList,
        promptsRender,
        directList,
        directSave,
        directRemove,
        directSetEnabled,
        directTest,
        directSetHistory,
        directSetPreferred,
        directOllamaModels,
        directOllamaLoad,
        directOllamaUnload,
        directOllamaKeepAlive,
        directOllamaThinking,
        mcpList,
        mcpSave,
        mcpRemove,
        mcpSetEnabled,
        mcpTest,
        mcpConnect,
        mcpCancelConnect,
        mcpDisconnect,
        mcpForgetApproval,
        mcpContent,
        mcpGetPrompt,
        mcpReadResource,
        turnsSend,
        turnsStop,
        turnsRegenerate,
        turnsEdit,
        turnsSteer,
        turnsRate,
        turnsMerge,
        handoffAnswer,
        turnsRetryQueued,
        turnsRemoveQueued,
        chatPromptsGet,
        chatPromptsAnswer,
        chatPromptsDecide,
        mcpAppsOpen,
        mcpAppsMessage,
        mcpAppsContext,
        mcpAppsClose,
        notesList,
        notesGet,
        notesSave,
        notesDelete,
        notesSetPinned,
        notesGenerateTitle,
        notesEnhance,
        notesAttach,
        notesDetach,
        channelsList,
        channelsSave,
        channelsDelete,
        channelsLeave,
        channelsMessages,
        channelsPost,
        channelsEditMessage,
        channelsDeleteMessage,
        channelsReact,
        channelsPin,
        channelsTyping,
        channelsMarkRead,
        channelsMembers,
        workspaceCapabilities,
        workspaceList,
        workspaceGet,
        workspaceSave,
        workspaceDelete,
        workspaceToggle,
        workspaceSetAccess,
        workspacePrincipals,
        workspaceExport,
        workspaceImport,
        workspaceModelOptions,
        workspacePromptHistory,
        workspacePromptDiff,
        workspacePromptSetVersion,
        workspacePromptDeleteVersion,
        workspaceValves,
        workspaceSaveValves,
        workspaceToolFromUrl,
        workspaceFiles,
        workspaceAttachFiles,
        workspaceFileAction,
        workspaceDirectoryAction,
        workspaceKnowledgeReset,
        workspaceKnowledgeCleanup,
        hermesSettings,
        hermesSaveSettings,
        hermesTest,
        hermesStatus,
        hermesSignIn,
        hermesSignOut,
        hermesSessions,
        hermesRenameSession,
        hermesDeleteSession,
        hermesForkSession,
        hermesJobs,
        hermesSaveJob,
        hermesSetJobEnabled,
        hermesRunJob,
        hermesDeleteJob,
        hermesCatalog,
        terminalServers,
        terminalSelect,
        terminalAttach,
        terminalList,
        terminalRead,
        terminalDownload,
        terminalFileAction,
        terminalPorts,
        terminalPreviewPort,
        voiceSettings,
        voiceSaveSettings,
        voiceVoices,
        voiceSpeak,
        voiceModels,
        voiceDownloadModel,
        voiceDeleteModel,
      ];

  static final Map<String, ConduitMethodSpec<Object?, Object?>> _byName =
      <String, ConduitMethodSpec<Object?, Object?>>{
        for (final spec in all) spec.name: spec,
      };

  /// The spec for [name], or null for a method this protocol does not have.
  static ConduitMethodSpec<Object?, Object?>? byName(String name) =>
      _byName[name];
}

/// Every event, with its payload and whether it is scoped.
///
/// [all] lists each one exactly once; the protocol tests hold it equal to
/// [ConduitEvents.all].
abstract final class ConduitEventSpecs {
  static const turnStarted = ConduitEventSpec<TurnStarted>(
    ConduitEvents.turnStarted,
    payload: TurnStarted.fromJson,
    scoped: true,
  );
  static const turnDelta = ConduitEventSpec<TurnDelta>(
    ConduitEvents.turnDelta,
    payload: TurnDelta.fromJson,
    scoped: true,
  );

  static const turnBlocks = ConduitEventSpec<TurnBlocks>(
    ConduitEvents.turnBlocks,
    payload: TurnBlocks.fromJson,
    scoped: true,
  );
  static const turnCompleted = ConduitEventSpec<TurnCompleted>(
    ConduitEvents.turnCompleted,
    payload: TurnCompleted.fromJson,
    scoped: true,
  );
  static const turnFailed = ConduitEventSpec<TurnFailed>(
    ConduitEvents.turnFailed,
    payload: TurnFailed.fromJson,
    scoped: true,
  );
  static const turnFinished = ConduitEventSpec<TurnFinished>(
    ConduitEvents.turnFinished,
    payload: TurnFinished.fromJson,
    scoped: false,
  );
  static const chatsChanged = ConduitEventSpec<ChatsChanged>(
    ConduitEvents.chatsChanged,
    payload: ChatsChanged.fromJson,
    scoped: false,
  );
  static const accountsChanged = ConduitEventSpec<AccountsChanged>(
    ConduitEvents.accountsChanged,
    payload: AccountsChanged.fromJson,
    scoped: false,
  );
  static const notesChanged = ConduitEventSpec<NotesChanged>(
    ConduitEvents.notesChanged,
    payload: NotesChanged.fromJson,
    scoped: false,
  );
  static const channelsMessage = ConduitEventSpec<ChannelMessagesChanged>(
    ConduitEvents.channelsMessage,
    payload: ChannelMessagesChanged.fromJson,
    scoped: true,
  );
  static const channelsTyping = ConduitEventSpec<ChannelTypingUsers>(
    ConduitEvents.channelsTyping,
    payload: ChannelTypingUsers.fromJson,
    scoped: true,
  );
  static const channelsChanged = ConduitEventSpec<void>(
    ConduitEvents.channelsChanged,
    scoped: false,
  );
  static const syncStatus = ConduitEventSpec<SyncState>(
    ConduitEvents.syncStatus,
    payload: SyncState.fromJson,
    scoped: false,
  );

  /// Reserved; not published yet.
  static const socketHealth = ConduitEventSpec<void>(
    ConduitEvents.socketHealth,
    scoped: false,
  );
  static const notifyShow = ConduitEventSpec<Notice>(
    ConduitEvents.notifyShow,
    payload: Notice.fromJson,
    scoped: false,
  );
  static const routeRemap = ConduitEventSpec<RouteRemap>(
    ConduitEvents.routeRemap,
    payload: RouteRemap.fromJson,
    scoped: false,
  );
  static const uiRequest = ConduitEventSpec<UiRequest>(
    ConduitEvents.uiRequest,
    payload: UiRequest.fromJson,
    scoped: false,
  );
  static const uiSettled = ConduitEventSpec<UiSettled>(
    ConduitEvents.uiSettled,
    payload: UiSettled.fromJson,
    scoped: false,
  );

  /// What the active account can use changed: another account, a server
  /// whose features or permissions changed, Hermes switched on or off. A
  /// window refetches `system.capabilities`.
  static const capabilitiesChanged = ConduitEventSpec<void>(
    ConduitEvents.capabilitiesChanged,
    scoped: false,
  );
  static const modelsChanged = ConduitEventSpec<void>(
    ConduitEvents.modelsChanged,
    scoped: false,
  );
  static const openUrl = ConduitEventSpec<OpenUrl>(
    ConduitEvents.openUrl,
    payload: OpenUrl.fromJson,
    scoped: false,
  );
  static const workspaceChanged = ConduitEventSpec<WorkspaceChanged>(
    ConduitEvents.workspaceChanged,
    payload: WorkspaceChanged.fromJson,
    scoped: false,
  );
  static const hermesChanged = ConduitEventSpec<void>(
    ConduitEvents.hermesChanged,
    scoped: false,
  );
  static const voiceChanged = ConduitEventSpec<VoiceModels>(
    ConduitEvents.voiceChanged,
    payload: VoiceModels.fromJson,
    scoped: false,
  );
  static const terminalDisplayFile = ConduitEventSpec<TerminalDisplayFile>(
    ConduitEvents.terminalDisplayFile,
    payload: TerminalDisplayFile.fromJson,
    scoped: true,
  );
  static const settingsChanged = ConduitEventSpec<void>(
    ConduitEvents.settingsChanged,
    scoped: false,
  );

  static const queueChanged = ConduitEventSpec<QueueState>(
    ConduitEvents.queueChanged,
    payload: QueueState.fromJson,
    scoped: true,
  );
  static const messagesMerge = ConduitEventSpec<MergeProgress>(
    ConduitEvents.messagesMerge,
    payload: MergeProgress.fromJson,
    scoped: true,
  );
  static const handoffRequested = ConduitEventSpec<HandoffRequest>(
    ConduitEvents.handoffRequested,
    payload: HandoffRequest.fromJson,
    scoped: false,
  );
  static const handoffSettled = ConduitEventSpec<HandoffSettled>(
    ConduitEvents.handoffSettled,
    payload: HandoffSettled.fromJson,
    scoped: false,
  );

  static const chatPromptsChanged = ConduitEventSpec<ChatPromptState>(
    ConduitEvents.chatPromptsChanged,
    payload: ChatPromptState.fromJson,
    scoped: true,
  );

  static const mcpAppsEvent = ConduitEventSpec<McpAppEvent>(
    ConduitEvents.mcpAppsEvent,
    payload: McpAppEvent.fromJson,
    scoped: true,
  );

  /// Every event, once.
  static const List<ConduitEventSpec<Object?>> all =
      <ConduitEventSpec<Object?>>[
        turnStarted,
        turnDelta,
        turnBlocks,
        turnCompleted,
        turnFailed,
        turnFinished,
        chatsChanged,
        accountsChanged,
        notesChanged,
        channelsMessage,
        channelsTyping,
        channelsChanged,
        syncStatus,
        socketHealth,
        notifyShow,
        routeRemap,
        uiRequest,
        uiSettled,
        capabilitiesChanged,
        modelsChanged,
        openUrl,
        workspaceChanged,
        hermesChanged,
        voiceChanged,
        terminalDisplayFile,
        settingsChanged,
        queueChanged,
        messagesMerge,
        handoffRequested,
        handoffSettled,
        chatPromptsChanged,
        mcpAppsEvent,
      ];

  static final Map<String, ConduitEventSpec<Object?>> _byName =
      <String, ConduitEventSpec<Object?>>{
        for (final spec in all) spec.name: spec,
      };

  /// The spec for [name], or null for an event this protocol does not have.
  static ConduitEventSpec<Object?>? byName(String name) => _byName[name];
}
