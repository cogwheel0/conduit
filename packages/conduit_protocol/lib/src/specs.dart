import 'access.dart';
import 'accounts.dart';
import 'auth.dart';
import 'automations.dart';
import 'calendar.dart';
import 'capabilities.dart';
import 'chat_prompts.dart';
import 'channels.dart';
import 'chat_settings.dart';
import 'chats.dart';
import 'composer.dart';
import 'computer.dart';
import 'data.dart';
import 'dictation.dart';
import 'direct.dart';
import 'events.dart';
import 'handoff.dart';
import 'handshake.dart';
import 'hermes.dart';
import 'hermes_admin.dart';
import 'hermes_rooms.dart';
import 'hermes_work.dart';
import 'intents.dart';
import 'integrations.dart';
import 'librechat.dart';
import 'mcp.dart';
import 'mcp_apps.dart';
import 'memories.dart';
import 'messages.dart';
import 'methods.dart';
import 'models.dart';
import 'notes.dart';
import 'notifications.dart';
import 'profile.dart';
import 'prompts.dart';
import 'release_notes.dart';
import 'queue.dart';
import 'recordings.dart';
import 'servers.dart';
import 'settings.dart';
import 'system.dart';
import 'terminal.dart';
import 'turns.dart';
import 'valves.dart';
import 'speech.dart';
import 'apple.dart';
import 'location.dart';
import 'calls.dart';
import 'voice.dart';
import 'web_search.dart';
import 'webhooks.dart';
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
  static const serversAddressesList =
      ConduitMethodSpec<ServerRef, ServerAddresses>(
        ConduitMethods.serversAddressesList,
        params: ServerRef.fromJson,
        result: ServerAddresses.fromJson,
      );
  static const serversAddressesCheck =
      ConduitMethodSpec<ServerAddressCheckRequest, ServerAddressCheckResult>(
        ConduitMethods.serversAddressesCheck,
        params: ServerAddressCheckRequest.fromJson,
        result: ServerAddressCheckResult.fromJson,
      );
  static const serversAddressesSave =
      ConduitMethodSpec<ServerAddressSaveRequest, ServerAddressSaveResult>(
        ConduitMethods.serversAddressesSave,
        params: ServerAddressSaveRequest.fromJson,
        result: ServerAddressSaveResult.fromJson,
      );
  static const serversAddressesRemove =
      ConduitMethodSpec<ServerAddressRemoveRequest, ServerAddressEditResult>(
        ConduitMethods.serversAddressesRemove,
        params: ServerAddressRemoveRequest.fromJson,
        result: ServerAddressEditResult.fromJson,
      );
  static const serversAddressesReorder =
      ConduitMethodSpec<ServerAddressReorderRequest, ServerAddressEditResult>(
        ConduitMethods.serversAddressesReorder,
        params: ServerAddressReorderRequest.fromJson,
        result: ServerAddressEditResult.fromJson,
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
  static const authTwoStepSetup = ConduitMethodSpec<void, TwoStepSetup>(
    ConduitMethods.authTwoStepSetup,
    result: TwoStepSetup.fromJson,
  );
  static const authTwoStepVerify = ConduitMethodSpec<TwoStepCode, AuthSnapshot>(
    ConduitMethods.authTwoStepVerify,
    params: TwoStepCode.fromJson,
    result: AuthSnapshot.fromJson,
  );
  static const authTwoStepRedeem =
      ConduitMethodSpec<TwoStepResetToken, AuthSnapshot>(
        ConduitMethods.authTwoStepRedeem,
        params: TwoStepResetToken.fromJson,
        result: AuthSnapshot.fromJson,
      );
  static const authTwoStepFinish = ConduitMethodSpec<void, AuthSnapshot>(
    ConduitMethods.authTwoStepFinish,
    result: AuthSnapshot.fromJson,
  );
  static const authTwoStepCancel = ConduitMethodSpec<void, AuthSnapshot>(
    ConduitMethods.authTwoStepCancel,
    result: AuthSnapshot.fromJson,
  );
  static const authRetry = ConduitMethodSpec<void, AuthSnapshot>(
    ConduitMethods.authRetry,
    result: AuthSnapshot.fromJson,
  );
  static const authRenewProxy =
      ConduitMethodSpec<ExternalAuthCompletion, AuthSnapshot>(
        ConduitMethods.authRenewProxy,
        params: ExternalAuthCompletion.fromJson,
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

  // notifications.*

  static const notificationsGet =
      ConduitMethodSpec<void, NotificationSettingsDto>(
        ConduitMethods.notificationsGet,
        result: NotificationSettingsDto.fromJson,
      );
  static const notificationsSet =
      ConduitMethodSpec<NotificationSettingsPatch, NotificationSettingsDto>(
        ConduitMethods.notificationsSet,
        params: NotificationSettingsPatch.fromJson,
        result: NotificationSettingsDto.fromJson,
      );
  static const notificationsRoute =
      ConduitMethodSpec<NotificationRouteParams, NotificationRoute>(
        ConduitMethods.notificationsRoute,
        params: NotificationRouteParams.fromJson,
        result: NotificationRoute.fromJson,
      );

  // webhooks.*

  static const webhooksList = ConduitMethodSpec<void, WebhookList>(
    ConduitMethods.webhooksList,
    result: WebhookList.fromJson,
  );
  static const webhooksCreate = ConduitMethodSpec<WebhookCreate, WebhookList>(
    ConduitMethods.webhooksCreate,
    params: WebhookCreate.fromJson,
    result: WebhookList.fromJson,
  );
  static const webhooksUpdate = ConduitMethodSpec<WebhookUpdate, WebhookList>(
    ConduitMethods.webhooksUpdate,
    params: WebhookUpdate.fromJson,
    result: WebhookList.fromJson,
  );
  static const webhooksMakeDefault = ConduitMethodSpec<WebhookRef, WebhookList>(
    ConduitMethods.webhooksMakeDefault,
    params: WebhookRef.fromJson,
    result: WebhookList.fromJson,
  );
  static const webhooksTest = ConduitMethodSpec<WebhookRef, WebhookList>(
    ConduitMethods.webhooksTest,
    params: WebhookRef.fromJson,
    result: WebhookList.fromJson,
  );
  static const webhooksDelete = ConduitMethodSpec<WebhookRef, WebhookList>(
    ConduitMethods.webhooksDelete,
    params: WebhookRef.fromJson,
    result: WebhookList.fromJson,
  );

  // integrations.*

  static const integrationsList = ConduitMethodSpec<void, PersonalConnections>(
    ConduitMethods.integrationsList,
    result: PersonalConnections.fromJson,
  );
  static const integrationsSave =
      ConduitMethodSpec<PersonalConnectionSave, PersonalConnections>(
        ConduitMethods.integrationsSave,
        params: PersonalConnectionSave.fromJson,
        result: PersonalConnections.fromJson,
      );
  static const integrationsTest =
      ConduitMethodSpec<PersonalConnectionTest, PersonalConnectionTestResult>(
        ConduitMethods.integrationsTest,
        params: PersonalConnectionTest.fromJson,
        result: PersonalConnectionTestResult.fromJson,
      );
  static const integrationsClearNotice =
      ConduitMethodSpec<void, PersonalConnections>(
        ConduitMethods.integrationsClearNotice,
        result: PersonalConnections.fromJson,
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
  static const dataReconnect = ConduitMethodSpec<void, ConnectionHealth>(
    ConduitMethods.dataReconnect,
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
  static const chatsGenerateTitle = ConduitMethodSpec<ChatRef, GeneratedTitle>(
    ConduitMethods.chatsGenerateTitle,
    params: ChatRef.fromJson,
    result: GeneratedTitle.fromJson,
  );
  static const chatsMarkUnread = ConduitMethodSpec<MarkUnread, ChatList>(
    ConduitMethods.chatsMarkUnread,
    params: MarkUnread.fromJson,
    result: ChatList.fromJson,
  );
  static const chatsSetShown = ConduitMethodSpec<ShownChat, OkResult>(
    ConduitMethods.chatsSetShown,
    params: ShownChat.fromJson,
    result: OkResult.fromJson,
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

  static const modelsList = ConduitMethodSpec<ModelListQuery, ModelList>(
    ConduitMethods.modelsList,
    params: ModelListQuery.fromJson,
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
  static const modelsControls =
      ConduitMethodSpec<ModelControlsQuery, ModelControlList>(
        ConduitMethods.modelsControls,
        params: ModelControlsQuery.fromJson,
        result: ModelControlList.fromJson,
      );
  static const modelsSetControl =
      ConduitMethodSpec<SetModelControl, ModelControlList>(
        ConduitMethods.modelsSetControl,
        params: SetModelControl.fromJson,
        result: ModelControlList.fromJson,
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
  static const composerOptions =
      ConduitMethodSpec<ComposerOptionsQuery, ComposerOptions>(
        ConduitMethods.composerOptions,
        params: ComposerOptionsQuery.fromJson,
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
  static const directReload = ConduitMethodSpec<void, DirectConnectionList>(
    ConduitMethods.directReload,
    result: DirectConnectionList.fromJson,
  );
  static const directOptions = ConduitMethodSpec<void, DirectOptions>(
    ConduitMethods.directOptions,
    result: DirectOptions.fromJson,
  );
  static const directSetImagesPerRequest =
      ConduitMethodSpec<DirectImagesPerRequest, DirectOptions>(
        ConduitMethods.directSetImagesPerRequest,
        params: DirectImagesPerRequest.fromJson,
        result: DirectOptions.fromJson,
      );
  static const directSetContextLimit =
      ConduitMethodSpec<DirectContextLimit, DirectOptions>(
        ConduitMethods.directSetContextLimit,
        params: DirectContextLimit.fromJson,
        result: DirectOptions.fromJson,
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

  // webSearch.*

  static const webSearchGet = ConduitMethodSpec<void, WebSearchSettings>(
    ConduitMethods.webSearchGet,
    result: WebSearchSettings.fromJson,
  );
  static const webSearchSet =
      ConduitMethodSpec<WebSearchSettingsPatch, WebSearchSettings>(
        ConduitMethods.webSearchSet,
        params: WebSearchSettingsPatch.fromJson,
        result: WebSearchSettings.fromJson,
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

  // speech.*

  static const speechGet = ConduitMethodSpec<void, SpeechState>(
    ConduitMethods.speechGet,
    result: SpeechState.fromJson,
  );
  static const speechToggle = ConduitMethodSpec<SpeechToggle, SpeechState>(
    ConduitMethods.speechToggle,
    params: SpeechToggle.fromJson,
    result: SpeechState.fromJson,
  );
  static const speechPause = ConduitMethodSpec<void, SpeechState>(
    ConduitMethods.speechPause,
    result: SpeechState.fromJson,
  );
  static const speechResume = ConduitMethodSpec<void, SpeechState>(
    ConduitMethods.speechResume,
    result: SpeechState.fromJson,
  );
  static const speechStop = ConduitMethodSpec<void, SpeechState>(
    ConduitMethods.speechStop,
    result: SpeechState.fromJson,
  );
  static const speechRetry = ConduitMethodSpec<void, SpeechState>(
    ConduitMethods.speechRetry,
    result: SpeechState.fromJson,
  );
  static const speechSeek = ConduitMethodSpec<SpeechSeek, SpeechState>(
    ConduitMethods.speechSeek,
    params: SpeechSeek.fromJson,
    result: SpeechState.fromJson,
  );
  static const speechPreview = ConduitMethodSpec<SpeechPreview, SpeechState>(
    ConduitMethods.speechPreview,
    params: SpeechPreview.fromJson,
    result: SpeechState.fromJson,
  );
  static const speechReport = ConduitMethodSpec<SpeechReport, OkResult>(
    ConduitMethods.speechReport,
    params: SpeechReport.fromJson,
    result: OkResult.fromJson,
  );

  // calls.*

  static const callsGet = ConduitMethodSpec<void, CallState>(
    ConduitMethods.callsGet,
    result: CallState.fromJson,
  );
  static const callsStart = ConduitMethodSpec<CallStart, CallState>(
    ConduitMethods.callsStart,
    params: CallStart.fromJson,
    result: CallState.fromJson,
  );
  static const callsEnd = ConduitMethodSpec<void, CallState>(
    ConduitMethods.callsEnd,
    result: CallState.fromJson,
  );
  static const callsPause = ConduitMethodSpec<void, CallState>(
    ConduitMethods.callsPause,
    result: CallState.fromJson,
  );
  static const callsResume = ConduitMethodSpec<void, CallState>(
    ConduitMethods.callsResume,
    result: CallState.fromJson,
  );
  static const callsMute = ConduitMethodSpec<void, CallState>(
    ConduitMethods.callsMute,
    result: CallState.fromJson,
  );
  static const callsSkip = ConduitMethodSpec<void, CallState>(
    ConduitMethods.callsSkip,
    result: CallState.fromJson,
  );
  // apple.*

  static const appleStatus = ConduitMethodSpec<void, AppleModels>(
    ConduitMethods.appleStatus,
    result: AppleModels.fromJson,
  );
  static const appleRefresh = ConduitMethodSpec<void, AppleModels>(
    ConduitMethods.appleRefresh,
    result: AppleModels.fromJson,
  );
  static const appleChoose = ConduitMethodSpec<void, AppleModelStatus>(
    ConduitMethods.appleChoose,
    result: AppleModelStatus.fromJson,
  );
  static const appleReport = ConduitMethodSpec<AppleReport, OkResult>(
    ConduitMethods.appleReport,
    params: AppleReport.fromJson,
    result: OkResult.fromJson,
  );

  static const callsReport = ConduitMethodSpec<CallReport, OkResult>(
    ConduitMethods.callsReport,
    params: CallReport.fromJson,
    result: OkResult.fromJson,
  );
  // calendar.*

  static const calendarAgenda =
      ConduitMethodSpec<CalendarAgendaQuery, CalendarAgenda>(
        ConduitMethods.calendarAgenda,
        params: CalendarAgendaQuery.fromJson,
        result: CalendarAgenda.fromJson,
      );
  static const calendarSetVisible =
      ConduitMethodSpec<CalendarVisibility, CalendarAgenda>(
        ConduitMethods.calendarSetVisible,
        params: CalendarVisibility.fromJson,
        result: CalendarAgenda.fromJson,
      );
  static const calendarMakeDefault =
      ConduitMethodSpec<CalendarRef, CalendarAgenda>(
        ConduitMethods.calendarMakeDefault,
        params: CalendarRef.fromJson,
        result: CalendarAgenda.fromJson,
      );
  static const calendarCreateCalendar =
      ConduitMethodSpec<CalendarCreate, CalendarDto>(
        ConduitMethods.calendarCreateCalendar,
        params: CalendarCreate.fromJson,
        result: CalendarDto.fromJson,
      );
  static const calendarEvent =
      ConduitMethodSpec<CalendarItemRef, CalendarEventDetail>(
        ConduitMethods.calendarEvent,
        params: CalendarItemRef.fromJson,
        result: CalendarEventDetail.fromJson,
      );
  static const calendarDeleteEvent =
      ConduitMethodSpec<CalendarItemRef, CalendarAgenda>(
        ConduitMethods.calendarDeleteEvent,
        params: CalendarItemRef.fromJson,
        result: CalendarAgenda.fromJson,
      );
  static const calendarRespond =
      ConduitMethodSpec<CalendarRsvpEdit, CalendarEventDetail>(
        ConduitMethods.calendarRespond,
        params: CalendarRsvpEdit.fromJson,
        result: CalendarEventDetail.fromJson,
      );
  static const calendarEditor =
      ConduitMethodSpec<CalendarEditorOpen, CalendarEditor>(
        ConduitMethods.calendarEditor,
        params: CalendarEditorOpen.fromJson,
        result: CalendarEditor.fromJson,
      );
  static const calendarCheckDraft =
      ConduitMethodSpec<CalendarDraftEdit, CalendarDraftState>(
        ConduitMethods.calendarCheckDraft,
        params: CalendarDraftEdit.fromJson,
        result: CalendarDraftState.fromJson,
      );
  static const calendarSave =
      ConduitMethodSpec<CalendarDraftEdit, CalendarDraftState>(
        ConduitMethods.calendarSave,
        params: CalendarDraftEdit.fromJson,
        result: CalendarDraftState.fromJson,
      );

  // automations.*

  static const automationsList =
      ConduitMethodSpec<AutomationQuery, AutomationList>(
        ConduitMethods.automationsList,
        params: AutomationQuery.fromJson,
        result: AutomationList.fromJson,
      );
  static const automationsLoadMore = ConduitMethodSpec<void, AutomationList>(
    ConduitMethods.automationsLoadMore,
    result: AutomationList.fromJson,
  );
  static const automationsGet =
      ConduitMethodSpec<AutomationRef, AutomationDetail>(
        ConduitMethods.automationsGet,
        params: AutomationRef.fromJson,
        result: AutomationDetail.fromJson,
      );
  static const automationsRuns =
      ConduitMethodSpec<AutomationRunsQuery, AutomationRuns>(
        ConduitMethods.automationsRuns,
        params: AutomationRunsQuery.fromJson,
        result: AutomationRuns.fromJson,
      );
  static const automationsSetActive =
      ConduitMethodSpec<AutomationToggle, AutomationDetail>(
        ConduitMethods.automationsSetActive,
        params: AutomationToggle.fromJson,
        result: AutomationDetail.fromJson,
      );
  static const automationsRun =
      ConduitMethodSpec<AutomationRef, AutomationRunProgress>(
        ConduitMethods.automationsRun,
        params: AutomationRef.fromJson,
        result: AutomationRunProgress.fromJson,
      );
  static const automationsRunState =
      ConduitMethodSpec<AutomationRef, AutomationRunProgress>(
        ConduitMethods.automationsRunState,
        params: AutomationRef.fromJson,
        result: AutomationRunProgress.fromJson,
      );
  static const automationsDelete =
      ConduitMethodSpec<AutomationRef, AutomationList>(
        ConduitMethods.automationsDelete,
        params: AutomationRef.fromJson,
        result: AutomationList.fromJson,
      );
  static const automationsEditor =
      ConduitMethodSpec<AutomationEditorOpen, AutomationEditor>(
        ConduitMethods.automationsEditor,
        params: AutomationEditorOpen.fromJson,
        result: AutomationEditor.fromJson,
      );
  static const automationsCheckDraft =
      ConduitMethodSpec<AutomationDraftEdit, AutomationDraftState>(
        ConduitMethods.automationsCheckDraft,
        params: AutomationDraftEdit.fromJson,
        result: AutomationDraftState.fromJson,
      );
  static const automationsSave =
      ConduitMethodSpec<AutomationDraftEdit, AutomationDraftState>(
        ConduitMethods.automationsSave,
        params: AutomationDraftEdit.fromJson,
        result: AutomationDraftState.fromJson,
      );
  static const automationsTerminals =
      ConduitMethodSpec<AutomationDraftEdit, AutomationTerminals>(
        ConduitMethods.automationsTerminals,
        params: AutomationDraftEdit.fromJson,
        result: AutomationTerminals.fromJson,
      );

  // notes.*

  static const notesList = ConduitMethodSpec<NoteQuery, NoteList>(
    ConduitMethods.notesList,
    params: NoteQuery.fromJson,
    result: NoteList.fromJson,
  );
  static const notesGet = ConduitMethodSpec<NoteOpen, NoteResult>(
    ConduitMethods.notesGet,
    params: NoteOpen.fromJson,
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
  static const notesRecordings = ConduitMethodSpec<NoteRef, NoteRecordings>(
    ConduitMethods.notesRecordings,
    params: NoteRef.fromJson,
    result: NoteRecordings.fromJson,
  );
  static const notesAddRecording =
      ConduitMethodSpec<NoteRecordingAdd, NoteRecordings>(
        ConduitMethods.notesAddRecording,
        params: NoteRecordingAdd.fromJson,
        result: NoteRecordings.fromJson,
      );
  static const notesRetryRecording =
      ConduitMethodSpec<NoteRecordingRef, NoteRecordings>(
        ConduitMethods.notesRetryRecording,
        params: NoteRecordingRef.fromJson,
        result: NoteRecordings.fromJson,
      );
  static const notesRemoveRecording =
      ConduitMethodSpec<NoteRecordingRef, NoteRecordings>(
        ConduitMethods.notesRemoveRecording,
        params: NoteRecordingRef.fromJson,
        result: NoteRecordings.fromJson,
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
  static const channelsOpen = ConduitMethodSpec<ChannelRef, ChannelDetails>(
    ConduitMethods.channelsOpen,
    params: ChannelRef.fromJson,
    result: ChannelDetails.fromJson,
  );
  static const channelsFocus = ConduitMethodSpec<ChannelFocus, OkResult>(
    ConduitMethods.channelsFocus,
    params: ChannelFocus.fromJson,
    result: OkResult.fromJson,
  );
  static const channelsSetMuted = ConduitMethodSpec<ChannelMute, ChannelList>(
    ConduitMethods.channelsSetMuted,
    params: ChannelMute.fromJson,
    result: ChannelList.fromJson,
  );
  static const channelsMentions =
      ConduitMethodSpec<ChannelMentionQuery, MentionList>(
        ConduitMethods.channelsMentions,
        params: ChannelMentionQuery.fromJson,
        result: MentionList.fromJson,
      );
  static const channelsMemberPage =
      ConduitMethodSpec<ChannelMemberQuery, ChannelMemberPage>(
        ConduitMethods.channelsMemberPage,
        params: ChannelMemberQuery.fromJson,
        result: ChannelMemberPage.fromJson,
      );
  static const channelsAddMembers =
      ConduitMethodSpec<ChannelMembersAdd, ChannelMemberChange>(
        ConduitMethods.channelsAddMembers,
        params: ChannelMembersAdd.fromJson,
        result: ChannelMemberChange.fromJson,
      );
  static const channelsRemoveMember =
      ConduitMethodSpec<ChannelMemberRemove, ChannelMemberChange>(
        ConduitMethods.channelsRemoveMember,
        params: ChannelMemberRemove.fromJson,
        result: ChannelMemberChange.fromJson,
      );
  static const channelsAppAction =
      ConduitMethodSpec<ChannelAppAction, ChannelAppActionResult>(
        ConduitMethods.channelsAppAction,
        params: ChannelAppAction.fromJson,
        result: ChannelAppActionResult.fromJson,
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
  static const workspaceDuplicate =
      ConduitMethodSpec<WorkspaceDuplicate, WorkspaceDetail>(
        ConduitMethods.workspaceDuplicate,
        params: WorkspaceDuplicate.fromJson,
        result: WorkspaceDetail.fromJson,
      );
  static const workspaceAddText =
      ConduitMethodSpec<WorkspaceTextFile, WorkspaceFiles>(
        ConduitMethods.workspaceAddText,
        params: WorkspaceTextFile.fromJson,
        result: WorkspaceFiles.fromJson,
      );
  static const workspaceSkillFromMarkdown =
      ConduitMethodSpec<WorkspaceMarkdown, WorkspaceSkillDto>(
        ConduitMethods.workspaceSkillFromMarkdown,
        params: WorkspaceMarkdown.fromJson,
        result: WorkspaceSkillDto.fromJson,
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
  static const hermesSignIn =
      ConduitMethodSpec<HermesSignInRequest, HermesSettings>(
        ConduitMethods.hermesSignIn,
        params: HermesSignInRequest.fromJson,
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
  static const hermesSessionsUpdate =
      ConduitMethodSpec<HermesSessionUpdate, HermesSessions>(
        ConduitMethods.hermesSessionsUpdate,
        params: HermesSessionUpdate.fromJson,
        result: HermesSessions.fromJson,
      );
  static const hermesSessionsContinue =
      ConduitMethodSpec<HermesContinue, HermesSessionDto>(
        ConduitMethods.hermesSessionsContinue,
        params: HermesContinue.fromJson,
        result: HermesSessionDto.fromJson,
      );
  static const hermesHiddenList = ConduitMethodSpec<void, HermesSessions>(
    ConduitMethods.hermesHiddenList,
    result: HermesSessions.fromJson,
  );
  static const hermesHistoryBranch =
      ConduitMethodSpec<HermesBranch, HermesSessionDto>(
        ConduitMethods.hermesHistoryBranch,
        params: HermesBranch.fromJson,
        result: HermesSessionDto.fromJson,
      );
  static const hermesHistoryUndo = ConduitMethodSpec<ChatRef, OkResult>(
    ConduitMethods.hermesHistoryUndo,
    params: ChatRef.fromJson,
    result: OkResult.fromJson,
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
  static const hermesRunJob = ConduitMethodSpec<HermesJobRef, HermesJobs>(
    ConduitMethods.hermesRunJob,
    params: HermesJobRef.fromJson,
    result: HermesJobs.fromJson,
  );
  static const hermesDeleteJob = ConduitMethodSpec<HermesJobRef, HermesJobs>(
    ConduitMethods.hermesDeleteJob,
    params: HermesJobRef.fromJson,
    result: HermesJobs.fromJson,
  );
  static const hermesCatalog = ConduitMethodSpec<void, HermesCatalog>(
    ConduitMethods.hermesCatalog,
    result: HermesCatalog.fromJson,
  );
  static const hermesJobsRuns = ConduitMethodSpec<HermesJobRef, HermesSessions>(
    ConduitMethods.hermesJobsRuns,
    params: HermesJobRef.fromJson,
    result: HermesSessions.fromJson,
  );
  static const hermesJobsStop = ConduitMethodSpec<HermesJobRef, HermesJobs>(
    ConduitMethods.hermesJobsStop,
    params: HermesJobRef.fromJson,
    result: HermesJobs.fromJson,
  );
  static const hermesJobsDelivery =
      ConduitMethodSpec<void, HermesDeliveryOptions>(
        ConduitMethods.hermesJobsDelivery,
        result: HermesDeliveryOptions.fromJson,
      );

  // hermes.connections.*

  static const hermesConnectionsList =
      ConduitMethodSpec<void, HermesConnections>(
        ConduitMethods.hermesConnectionsList,
        result: HermesConnections.fromJson,
      );
  static const hermesConnectionsSave =
      ConduitMethodSpec<HermesConnectionEdit, HermesConnections>(
        ConduitMethods.hermesConnectionsSave,
        params: HermesConnectionEdit.fromJson,
        result: HermesConnections.fromJson,
      );
  static const hermesConnectionsTest =
      ConduitMethodSpec<HermesConnectionEdit, HermesConnectionTestResult>(
        ConduitMethods.hermesConnectionsTest,
        params: HermesConnectionEdit.fromJson,
        result: HermesConnectionTestResult.fromJson,
      );
  static const hermesConnectionsActivate =
      ConduitMethodSpec<HermesRef, HermesConnections>(
        ConduitMethods.hermesConnectionsActivate,
        params: HermesRef.fromJson,
        result: HermesConnections.fromJson,
      );
  static const hermesConnectionsDelete =
      ConduitMethodSpec<HermesRef, HermesConnections>(
        ConduitMethods.hermesConnectionsDelete,
        params: HermesRef.fromJson,
        result: HermesConnections.fromJson,
      );
  static const hermesConnectionsSetEnabled =
      ConduitMethodSpec<HermesToggle, HermesConnections>(
        ConduitMethods.hermesConnectionsSetEnabled,
        params: HermesToggle.fromJson,
        result: HermesConnections.fromJson,
      );
  static const hermesConnectionsProfiles =
      ConduitMethodSpec<HermesConnectionEdit, HermesProfiles>(
        ConduitMethods.hermesConnectionsProfiles,
        params: HermesConnectionEdit.fromJson,
        result: HermesProfiles.fromJson,
      );

  // hermes.toolsets.*, hermes.skills.*

  static const hermesToolsetsSet =
      ConduitMethodSpec<HermesToolsetToggle, HermesCatalog>(
        ConduitMethods.hermesToolsetsSet,
        params: HermesToolsetToggle.fromJson,
        result: HermesCatalog.fromJson,
      );
  static const hermesSkillsReload =
      ConduitMethodSpec<HermesConnectionRef, HermesCatalog>(
        ConduitMethods.hermesSkillsReload,
        params: HermesConnectionRef.fromJson,
        result: HermesCatalog.fromJson,
      );

  // hermes.dashboard.*

  static const hermesDashboardStart =
      ConduitMethodSpec<HermesDashboardStart, HermesDashboardPlan>(
        ConduitMethods.hermesDashboardStart,
        params: HermesDashboardStart.fromJson,
        result: HermesDashboardPlan.fromJson,
      );
  static const hermesDashboardComplete =
      ConduitMethodSpec<HermesDashboardCookies, HermesDashboardResult>(
        ConduitMethods.hermesDashboardComplete,
        params: HermesDashboardCookies.fromJson,
        result: HermesDashboardResult.fromJson,
      );
  static const hermesDashboardCancel =
      ConduitMethodSpec<HermesDashboardCancel, CancelledResult>(
        ConduitMethods.hermesDashboardCancel,
        params: HermesDashboardCancel.fromJson,
        result: CancelledResult.fromJson,
      );

  // hermes.mcp.*

  static const hermesMcpList = ConduitMethodSpec<void, HermesMcpServers>(
    ConduitMethods.hermesMcpList,
    result: HermesMcpServers.fromJson,
  );
  static const hermesMcpCatalog = ConduitMethodSpec<void, HermesMcpCatalog>(
    ConduitMethods.hermesMcpCatalog,
    result: HermesMcpCatalog.fromJson,
  );
  static const hermesMcpAdd = ConduitMethodSpec<HermesMcpAdd, HermesMcpServers>(
    ConduitMethods.hermesMcpAdd,
    params: HermesMcpAdd.fromJson,
    result: HermesMcpServers.fromJson,
  );
  static const hermesMcpAddFromCatalog =
      ConduitMethodSpec<HermesMcpCatalogAdd, HermesMcpCatalogAdded>(
        ConduitMethods.hermesMcpAddFromCatalog,
        params: HermesMcpCatalogAdd.fromJson,
        result: HermesMcpCatalogAdded.fromJson,
      );
  static const hermesMcpSetApiKey =
      ConduitMethodSpec<HermesMcpApiKey, HermesMcpServers>(
        ConduitMethods.hermesMcpSetApiKey,
        params: HermesMcpApiKey.fromJson,
        result: HermesMcpServers.fromJson,
      );
  static const hermesMcpRemove =
      ConduitMethodSpec<HermesMcpRef, HermesMcpServers>(
        ConduitMethods.hermesMcpRemove,
        params: HermesMcpRef.fromJson,
        result: HermesMcpServers.fromJson,
      );
  static const hermesMcpTest =
      ConduitMethodSpec<HermesMcpRef, HermesMcpTestResultDto>(
        ConduitMethods.hermesMcpTest,
        params: HermesMcpRef.fromJson,
        result: HermesMcpTestResultDto.fromJson,
      );
  static const hermesMcpSetEnabled =
      ConduitMethodSpec<HermesMcpToggle, HermesMcpServers>(
        ConduitMethods.hermesMcpSetEnabled,
        params: HermesMcpToggle.fromJson,
        result: HermesMcpServers.fromJson,
      );
  static const hermesMcpAuthenticate =
      ConduitMethodSpec<HermesMcpRef, HermesMcpServers>(
        ConduitMethods.hermesMcpAuthenticate,
        params: HermesMcpRef.fromJson,
        result: HermesMcpServers.fromJson,
      );

  // hermes.work.*, hermes.context.*, hermes.decisions.*

  static const hermesWorkWatch = ConduitMethodSpec<HermesWorkWatch, HermesWork>(
    ConduitMethods.hermesWorkWatch,
    params: HermesWorkWatch.fromJson,
    result: HermesWork.fromJson,
  );
  static const hermesWorkUnwatch = ConduitMethodSpec<HermesWorkChat, OkResult>(
    ConduitMethods.hermesWorkUnwatch,
    params: HermesWorkChat.fromJson,
    result: OkResult.fromJson,
  );
  static const hermesWorkSteer =
      ConduitMethodSpec<HermesSteerSubagent, OkResult>(
        ConduitMethods.hermesWorkSteer,
        params: HermesSteerSubagent.fromJson,
        result: OkResult.fromJson,
      );
  static const hermesWorkStop = ConduitMethodSpec<HermesSubagentRef, OkResult>(
    ConduitMethods.hermesWorkStop,
    params: HermesSubagentRef.fromJson,
    result: OkResult.fromJson,
  );
  static const hermesWorkKill =
      ConduitMethodSpec<HermesProcessRef, HermesProcessKill>(
        ConduitMethods.hermesWorkKill,
        params: HermesProcessRef.fromJson,
        result: HermesProcessKill.fromJson,
      );
  static const hermesContextGet =
      ConduitMethodSpec<HermesContextRef, HermesContextReportDto>(
        ConduitMethods.hermesContextGet,
        params: HermesContextRef.fromJson,
        result: HermesContextReportDto.fromJson,
      );
  static const hermesContextCompact =
      ConduitMethodSpec<HermesCompact, HermesCompactResultDto>(
        ConduitMethods.hermesContextCompact,
        params: HermesCompact.fromJson,
        result: HermesCompactResultDto.fromJson,
      );
  static const hermesDecisionsAnswer =
      ConduitMethodSpec<HermesDecisionAnswer, HermesDecisionResult>(
        ConduitMethods.hermesDecisionsAnswer,
        params: HermesDecisionAnswer.fromJson,
        result: HermesDecisionResult.fromJson,
      );

  // hermes.bots.*, hermes.rooms.*

  static const hermesBotsList = ConduitMethodSpec<void, HermesBots>(
    ConduitMethods.hermesBotsList,
    result: HermesBots.fromJson,
  );
  static const hermesBotsAvatar =
      ConduitMethodSpec<HermesBotRef, HermesBotAvatar>(
        ConduitMethods.hermesBotsAvatar,
        params: HermesBotRef.fromJson,
        result: HermesBotAvatar.fromJson,
      );
  static const hermesBotsOpen =
      ConduitMethodSpec<HermesBotRef, HermesSessionDto>(
        ConduitMethods.hermesBotsOpen,
        params: HermesBotRef.fromJson,
        result: HermesSessionDto.fromJson,
      );
  static const hermesRoomsList = ConduitMethodSpec<void, HermesRooms>(
    ConduitMethods.hermesRoomsList,
    result: HermesRooms.fromJson,
  );
  static const hermesRoomsCreate =
      ConduitMethodSpec<HermesRoomCreate, HermesRoomDto>(
        ConduitMethods.hermesRoomsCreate,
        params: HermesRoomCreate.fromJson,
        result: HermesRoomDto.fromJson,
      );
  static const hermesRoomsWatch =
      ConduitMethodSpec<HermesRoomRef, HermesRoomView>(
        ConduitMethods.hermesRoomsWatch,
        params: HermesRoomRef.fromJson,
        result: HermesRoomView.fromJson,
      );
  static const hermesRoomsUnwatch = ConduitMethodSpec<HermesRoomRef, OkResult>(
    ConduitMethods.hermesRoomsUnwatch,
    params: HermesRoomRef.fromJson,
    result: OkResult.fromJson,
  );
  static const hermesRoomsSend =
      ConduitMethodSpec<HermesRoomMessage, HermesRoomSendResult>(
        ConduitMethods.hermesRoomsSend,
        params: HermesRoomMessage.fromJson,
        result: HermesRoomSendResult.fromJson,
      );
  static const hermesRoomsStop =
      ConduitMethodSpec<HermesRoomRef, HermesRoomStopped>(
        ConduitMethods.hermesRoomsStop,
        params: HermesRoomRef.fromJson,
        result: HermesRoomStopped.fromJson,
      );
  static const hermesRoomsContinue =
      ConduitMethodSpec<HermesRoomContinue, OkResult>(
        ConduitMethods.hermesRoomsContinue,
        params: HermesRoomContinue.fromJson,
        result: OkResult.fromJson,
      );
  static const hermesRoomsAnswer =
      ConduitMethodSpec<HermesRoomAnswer, OkResult>(
        ConduitMethods.hermesRoomsAnswer,
        params: HermesRoomAnswer.fromJson,
        result: OkResult.fromJson,
      );
  static const hermesRoomsRename =
      ConduitMethodSpec<HermesRoomRename, HermesRoomDto>(
        ConduitMethods.hermesRoomsRename,
        params: HermesRoomRename.fromJson,
        result: HermesRoomDto.fromJson,
      );
  static const hermesRoomsSaveContext =
      ConduitMethodSpec<HermesRoomContextEdit, HermesRoomContextDto>(
        ConduitMethods.hermesRoomsSaveContext,
        params: HermesRoomContextEdit.fromJson,
        result: HermesRoomContextDto.fromJson,
      );
  static const hermesRoomsDisband = ConduitMethodSpec<HermesRoomRef, OkResult>(
    ConduitMethods.hermesRoomsDisband,
    params: HermesRoomRef.fromJson,
    result: OkResult.fromJson,
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
  static const terminalWatch =
      ConduitMethodSpec<TerminalWatch, TerminalWatching>(
        ConduitMethods.terminalWatch,
        params: TerminalWatch.fromJson,
        result: TerminalWatching.fromJson,
      );
  static const terminalDetach = ConduitMethodSpec<TerminalHandleRef, OkResult>(
    ConduitMethods.terminalDetach,
    params: TerminalHandleRef.fromJson,
    result: OkResult.fromJson,
  );

  // computer.*

  static const computerStatus =
      ConduitMethodSpec<ComputerScope, ComputerStatus>(
        ConduitMethods.computerStatus,
        params: ComputerScope.fromJson,
        result: ComputerStatus.fromJson,
      );
  static const computerOpen = ConduitMethodSpec<ComputerOpen, ComputerView>(
    ConduitMethods.computerOpen,
    params: ComputerOpen.fromJson,
    result: ComputerView.fromJson,
  );
  static const computerTabs = ConduitMethodSpec<ComputerScope, ComputerTabs>(
    ConduitMethods.computerTabs,
    params: ComputerScope.fromJson,
    result: ComputerTabs.fromJson,
  );
  static const computerCloseTab = ConduitMethodSpec<ComputerTabRef, OkResult>(
    ConduitMethods.computerCloseTab,
    params: ComputerTabRef.fromJson,
    result: OkResult.fromJson,
  );
  static const computerShortcut = ConduitMethodSpec<ComputerShortcut, OkResult>(
    ConduitMethods.computerShortcut,
    params: ComputerShortcut.fromJson,
    result: OkResult.fromJson,
  );
  static const computerClose = ConduitMethodSpec<ComputerHandleRef, OkResult>(
    ConduitMethods.computerClose,
    params: ComputerHandleRef.fromJson,
    result: OkResult.fromJson,
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

  // dictation.*
  static const dictationStatus =
      ConduitMethodSpec<DictationTarget, DictationStatus>(
        ConduitMethods.dictationStatus,
        params: DictationTarget.fromJson,
        result: DictationStatus.fromJson,
      );

  // recordings.*
  static const recordingsList =
      ConduitMethodSpec<RecordingTarget, RecordingList>(
        ConduitMethods.recordingsList,
        params: RecordingTarget.fromJson,
        result: RecordingList.fromJson,
      );
  static const recordingsBegin =
      ConduitMethodSpec<RecordingTarget, RecordingStarted>(
        ConduitMethods.recordingsBegin,
        params: RecordingTarget.fromJson,
        result: RecordingStarted.fromJson,
      );
  static const recordingsAppend =
      ConduitMethodSpec<RecordingChunk, RecordingSaved>(
        ConduitMethods.recordingsAppend,
        params: RecordingChunk.fromJson,
        result: RecordingSaved.fromJson,
      );
  static const recordingsClose =
      ConduitMethodSpec<RecordingRef, RecordingSaved>(
        ConduitMethods.recordingsClose,
        params: RecordingRef.fromJson,
        result: RecordingSaved.fromJson,
      );
  static const recordingsDiscard =
      ConduitMethodSpec<RecordingRef, RecordingList>(
        ConduitMethods.recordingsDiscard,
        params: RecordingRef.fromJson,
        result: RecordingList.fromJson,
      );
  static const recordingsTranscribe =
      ConduitMethodSpec<RecordingTranscribe, VoiceTranscript>(
        ConduitMethods.recordingsTranscribe,
        params: RecordingTranscribe.fromJson,
        result: VoiceTranscript.fromJson,
      );

  // librechat.*

  static const librechatProbe =
      ConduitMethodSpec<LibreChatProbe, LibreChatProbeResult>(
        ConduitMethods.librechatProbe,
        params: LibreChatProbe.fromJson,
        result: LibreChatProbeResult.fromJson,
      );
  static const librechatSignIn =
      ConduitMethodSpec<LibreChatSignIn, LibreChatSignInResult>(
        ConduitMethods.librechatSignIn,
        params: LibreChatSignIn.fromJson,
        result: LibreChatSignInResult.fromJson,
      );
  static const librechatVerify =
      ConduitMethodSpec<LibreChatVerify, LibreChatSignInResult>(
        ConduitMethods.librechatVerify,
        params: LibreChatVerify.fromJson,
        result: LibreChatSignInResult.fromJson,
      );
  static const librechatSsoStart =
      ConduitMethodSpec<LibreChatSsoStart, LibreChatSsoPlan>(
        ConduitMethods.librechatSsoStart,
        params: LibreChatSsoStart.fromJson,
        result: LibreChatSsoPlan.fromJson,
      );
  static const librechatCompleteSso =
      ConduitMethodSpec<LibreChatSsoCompletion, LibreChatSignInResult>(
        ConduitMethods.librechatCompleteSso,
        params: LibreChatSsoCompletion.fromJson,
        result: LibreChatSignInResult.fromJson,
      );
  static const librechatComposer =
      ConduitMethodSpec<LibreChatComposerTarget, LibreChatComposer>(
        ConduitMethods.librechatComposer,
        params: LibreChatComposerTarget.fromJson,
        result: LibreChatComposer.fromJson,
      );
  static const librechatMemoriesList =
      ConduitMethodSpec<void, LibreChatMemories>(
        ConduitMethods.librechatMemoriesList,
        result: LibreChatMemories.fromJson,
      );
  static const librechatMemoriesSave =
      ConduitMethodSpec<LibreChatMemoryEdit, LibreChatMemories>(
        ConduitMethods.librechatMemoriesSave,
        params: LibreChatMemoryEdit.fromJson,
        result: LibreChatMemories.fromJson,
      );
  static const librechatMemoriesDelete =
      ConduitMethodSpec<LibreChatMemoryRef, LibreChatMemories>(
        ConduitMethods.librechatMemoriesDelete,
        params: LibreChatMemoryRef.fromJson,
        result: LibreChatMemories.fromJson,
      );
  static const librechatMemoriesSetEnabled =
      ConduitMethodSpec<LibreChatMemoryToggle, LibreChatMemories>(
        ConduitMethods.librechatMemoriesSetEnabled,
        params: LibreChatMemoryToggle.fromJson,
        result: LibreChatMemories.fromJson,
      );
  static const librechatDuplicate = ConduitMethodSpec<ChatRef, ChatForked>(
    ConduitMethods.librechatDuplicate,
    params: ChatRef.fromJson,
    result: ChatForked.fromJson,
  );

  // intents.*
  static const intentsAsk = ConduitMethodSpec<IntentAsk, IntentAnswer>(
    ConduitMethods.intentsAsk,
    params: IntentAsk.fromJson,
    result: IntentAnswer.fromJson,
  );
  static const intentsChats = ConduitMethodSpec<IntentChatsQuery, IntentChats>(
    ConduitMethods.intentsChats,
    params: IntentChatsQuery.fromJson,
    result: IntentChats.fromJson,
  );
  static const intentsSendLink =
      ConduitMethodSpec<IntentLink, IntentLinkResult>(
        ConduitMethods.intentsSendLink,
        params: IntentLink.fromJson,
        result: IntentLinkResult.fromJson,
      );

  // location.*
  static const locationReport = ConduitMethodSpec<LocationReport, OkResult>(
    ConduitMethods.locationReport,
    params: LocationReport.fromJson,
    result: OkResult.fromJson,
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
        serversAddressesList,
        serversAddressesCheck,
        serversAddressesSave,
        serversAddressesRemove,
        serversAddressesReorder,
        serversStatus,
        authStatus,
        authLoginWithPassword,
        authLoginWithLdap,
        authLoginWithApiKey,
        authSilentLogin,
        authCompleteExternal,
        authHasSavedCredentials,
        authSetReviewerMode,
        authTwoStepSetup,
        authTwoStepVerify,
        authTwoStepRedeem,
        authTwoStepFinish,
        authTwoStepCancel,
        authRetry,
        authRenewProxy,
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
        notificationsGet,
        notificationsSet,
        notificationsRoute,
        webhooksList,
        webhooksCreate,
        webhooksUpdate,
        webhooksMakeDefault,
        webhooksTest,
        webhooksDelete,
        integrationsList,
        integrationsSave,
        integrationsTest,
        integrationsClearNotice,
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
        dataReconnect,
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
        chatsSetShown,
        chatsSaveTemporary,
        messagesDelete,
        modelsList,
        modelsSelect,
        modelsSetPinned,
        modelsOptions,
        modelsSetReasoningEffort,
        modelsSetFastTier,
        modelsControls,
        modelsSetControl,
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
        directReload,
        directOptions,
        directSetImagesPerRequest,
        directSetContextLimit,
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
        webSearchGet,
        webSearchSet,
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
        speechGet,
        speechToggle,
        speechPause,
        speechResume,
        speechStop,
        speechRetry,
        speechSeek,
        speechPreview,
        speechReport,
        callsGet,
        callsStart,
        callsEnd,
        callsPause,
        callsResume,
        callsMute,
        callsSkip,
        callsReport,
        calendarAgenda,
        calendarSetVisible,
        calendarMakeDefault,
        calendarCreateCalendar,
        calendarEvent,
        calendarDeleteEvent,
        calendarRespond,
        calendarEditor,
        calendarCheckDraft,
        calendarSave,
        automationsList,
        automationsLoadMore,
        automationsGet,
        automationsRuns,
        automationsSetActive,
        automationsRun,
        automationsRunState,
        automationsDelete,
        automationsEditor,
        automationsCheckDraft,
        automationsSave,
        automationsTerminals,
        appleStatus,
        appleRefresh,
        appleChoose,
        appleReport,
        notesList,
        notesGet,
        notesSave,
        notesDelete,
        notesSetPinned,
        notesGenerateTitle,
        notesEnhance,
        notesAttach,
        notesDetach,
        notesRecordings,
        notesAddRecording,
        notesRetryRecording,
        notesRemoveRecording,
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
        channelsOpen,
        channelsFocus,
        channelsSetMuted,
        channelsMentions,
        channelsMemberPage,
        channelsAddMembers,
        channelsRemoveMember,
        channelsAppAction,
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
        workspaceDuplicate,
        workspaceAddText,
        workspaceSkillFromMarkdown,
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
        hermesSessionsUpdate,
        hermesSessionsContinue,
        hermesHiddenList,
        hermesHistoryBranch,
        hermesHistoryUndo,
        hermesJobs,
        hermesSaveJob,
        hermesSetJobEnabled,
        hermesRunJob,
        hermesDeleteJob,
        hermesCatalog,
        hermesJobsRuns,
        hermesJobsStop,
        hermesJobsDelivery,
        hermesConnectionsList,
        hermesConnectionsSave,
        hermesConnectionsTest,
        hermesConnectionsActivate,
        hermesConnectionsDelete,
        hermesConnectionsSetEnabled,
        hermesConnectionsProfiles,
        hermesToolsetsSet,
        hermesSkillsReload,
        hermesDashboardStart,
        hermesDashboardComplete,
        hermesDashboardCancel,
        hermesMcpList,
        hermesMcpCatalog,
        hermesMcpAdd,
        hermesMcpAddFromCatalog,
        hermesMcpSetApiKey,
        hermesMcpRemove,
        hermesMcpTest,
        hermesMcpSetEnabled,
        hermesMcpAuthenticate,
        hermesWorkWatch,
        hermesWorkUnwatch,
        hermesWorkSteer,
        hermesWorkStop,
        hermesWorkKill,
        hermesContextGet,
        hermesContextCompact,
        hermesDecisionsAnswer,
        hermesBotsList,
        hermesBotsAvatar,
        hermesBotsOpen,
        hermesRoomsList,
        hermesRoomsCreate,
        hermesRoomsWatch,
        hermesRoomsUnwatch,
        hermesRoomsSend,
        hermesRoomsStop,
        hermesRoomsContinue,
        hermesRoomsAnswer,
        hermesRoomsRename,
        hermesRoomsSaveContext,
        hermesRoomsDisband,
        terminalServers,
        terminalSelect,
        terminalAttach,
        terminalList,
        terminalRead,
        terminalDownload,
        terminalFileAction,
        terminalPorts,
        terminalPreviewPort,
        terminalWatch,
        terminalDetach,
        computerStatus,
        computerOpen,
        computerTabs,
        computerCloseTab,
        computerShortcut,
        computerClose,
        voiceSettings,
        voiceSaveSettings,
        voiceVoices,
        voiceSpeak,
        voiceModels,
        voiceDownloadModel,
        voiceDeleteModel,
        dictationStatus,
        recordingsList,
        recordingsBegin,
        recordingsAppend,
        recordingsClose,
        recordingsDiscard,
        recordingsTranscribe,
        librechatProbe,
        librechatSignIn,
        librechatVerify,
        librechatSsoStart,
        librechatCompleteSso,
        librechatComposer,
        librechatMemoriesList,
        librechatMemoriesSave,
        librechatMemoriesDelete,
        librechatMemoriesSetEnabled,
        librechatDuplicate,
        intentsAsk,
        intentsChats,
        intentsSendLink,
        locationReport,
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
  static const serversChanged = ConduitEventSpec<ServersChanged>(
    ConduitEvents.serversChanged,
    payload: ServersChanged.fromJson,
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
  static const channelsAppReply = ConduitEventSpec<ChannelAppReplyEvent>(
    ConduitEvents.channelsAppReply,
    payload: ChannelAppReplyEvent.fromJson,
    scoped: true,
  );
  static const channelsPosted = ConduitEventSpec<ChannelPosted>(
    ConduitEvents.channelsPosted,
    payload: ChannelPosted.fromJson,
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
  static const hermesChanged = ConduitEventSpec<HermesChanged>(
    ConduitEvents.hermesChanged,
    payload: HermesChanged.fromJson,
    scoped: false,
  );
  static const authChanged = ConduitEventSpec<void>(
    ConduitEvents.authChanged,
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
  static const terminalChanged = ConduitEventSpec<TerminalChanged>(
    ConduitEvents.terminalChanged,
    payload: TerminalChanged.fromJson,
    scoped: false,
  );
  static const settingsChanged = ConduitEventSpec<void>(
    ConduitEvents.settingsChanged,
    scoped: false,
  );
  static const notificationsChanged = ConduitEventSpec<void>(
    ConduitEvents.notificationsChanged,
    scoped: false,
  );
  static const notificationsAnswered = ConduitEventSpec<AnswerNotice>(
    ConduitEvents.notificationsAnswered,
    payload: AnswerNotice.fromJson,
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

  static const speechChanged = ConduitEventSpec<SpeechProgress>(
    ConduitEvents.speechChanged,
    payload: SpeechProgress.fromJson,
    scoped: false,
  );
  static const speechCommand = ConduitEventSpec<SpeechCommand>(
    ConduitEvents.speechCommand,
    payload: SpeechCommand.fromJson,
    scoped: false,
  );
  static const callsChanged = ConduitEventSpec<CallState>(
    ConduitEvents.callsChanged,
    payload: CallState.fromJson,
    scoped: false,
  );
  static const appleCommand = ConduitEventSpec<AppleCommand>(
    ConduitEvents.appleCommand,
    payload: AppleCommand.fromJson,
    scoped: false,
  );
  static const locationCommand = ConduitEventSpec<LocationCommand>(
    ConduitEvents.locationCommand,
    payload: LocationCommand.fromJson,
    scoped: false,
  );
  static const composerInsertText = ConduitEventSpec<ComposerInsertText>(
    ConduitEvents.composerInsertText,
    payload: ComposerInsertText.fromJson,
    scoped: true,
  );
  static const callsCommand = ConduitEventSpec<CallCommand>(
    ConduitEvents.callsCommand,
    payload: CallCommand.fromJson,
    scoped: false,
  );

  static const hermesWorkChanged = ConduitEventSpec<HermesWork>(
    ConduitEvents.hermesWorkChanged,
    payload: HermesWork.fromJson,
    scoped: true,
  );

  static const calendarChanged = ConduitEventSpec<void>(
    ConduitEvents.calendarChanged,
    scoped: false,
  );
  static const automationsChanged = ConduitEventSpec<void>(
    ConduitEvents.automationsChanged,
    scoped: false,
  );
  static const automationsRunProgress = ConduitEventSpec<AutomationRunProgress>(
    ConduitEvents.automationsRunProgress,
    payload: AutomationRunProgress.fromJson,
    scoped: false,
  );

  static const hermesRoomsChanged = ConduitEventSpec<HermesRoomView>(
    ConduitEvents.hermesRoomsChanged,
    payload: HermesRoomView.fromJson,
    scoped: true,
  );
  static const hermesRoomsListChanged = ConduitEventSpec<HermesRooms>(
    ConduitEvents.hermesRoomsListChanged,
    payload: HermesRooms.fromJson,
    scoped: false,
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
        serversChanged,
        notesChanged,
        channelsMessage,
        channelsTyping,
        channelsChanged,
        channelsAppReply,
        channelsPosted,
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
        authChanged,
        voiceChanged,
        terminalDisplayFile,
        terminalChanged,
        settingsChanged,
        notificationsChanged,
        notificationsAnswered,
        queueChanged,
        messagesMerge,
        handoffRequested,
        handoffSettled,
        chatPromptsChanged,
        mcpAppsEvent,
        speechChanged,
        speechCommand,
        hermesWorkChanged,
        callsChanged,
        callsCommand,
        calendarChanged,
        automationsChanged,
        automationsRunProgress,
        hermesRoomsChanged,
        hermesRoomsListChanged,
        appleCommand,
        locationCommand,
        composerInsertText,
      ];

  static final Map<String, ConduitEventSpec<Object?>> _byName =
      <String, ConduitEventSpec<Object?>>{
        for (final spec in all) spec.name: spec,
      };

  /// The spec for [name], or null for an event this protocol does not have.
  static ConduitEventSpec<Object?>? byName(String name) => _byName[name];
}
