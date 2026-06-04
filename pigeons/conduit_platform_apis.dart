import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/core/platform/conduit_platform_apis.g.dart',
    dartOptions: DartOptions(),
    kotlinOut:
        'android/app/src/main/kotlin/app/cogwheel/conduit/ConduitPlatformApis.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.cogwheel.conduit'),
    swiftOut: 'ios/Runner/ConduitPlatformApis.g.swift',
    swiftOptions: SwiftOptions(),
    dartPackageName: 'conduit',
  ),
)
enum PlatformBackgroundStreamKind { chat, voice }

enum PlatformNativePasteKind { text, images, unsupported }

enum PlatformNativeSheetItemKind {
  navigation,
  textField,
  multilineTextField,
  secureTextField,
  dropdown,
  searchablePicker,
  toggle,
  segment,
  slider,
  info,
  readOnlyText,
  source,
  statusUpdate,
}

class PlatformBackgroundStreamLease {
  PlatformBackgroundStreamLease({
    required this.id,
    required this.kind,
    required this.requiresMicrophone,
    required this.startedAtMillis,
  });

  String id;
  PlatformBackgroundStreamKind kind;
  bool requiresMicrophone;
  int startedAtMillis;
}

class PlatformBackgroundStartRequest {
  PlatformBackgroundStartRequest({
    required this.streamIds,
    required this.requiresMicrophone,
    required this.leases,
  });

  List<String> streamIds;
  bool requiresMicrophone;
  List<PlatformBackgroundStreamLease> leases;
}

class PlatformBackgroundStopRequest {
  PlatformBackgroundStopRequest({required this.streamIds});

  List<String> streamIds;
}

class PlatformBackgroundKeepAliveRequest {
  PlatformBackgroundKeepAliveRequest({
    required this.streamCount,
    required this.leases,
  });

  int streamCount;
  List<PlatformBackgroundStreamLease> leases;
}

class PlatformBackgroundAudioSessionOwnerRequest {
  PlatformBackgroundAudioSessionOwnerRequest({required this.isExternal});

  bool isExternal;
}

class PlatformServiceFailureEvent {
  PlatformServiceFailureEvent({
    required this.error,
    required this.errorType,
    required this.streamIds,
  });

  String error;
  String errorType;
  List<String> streamIds;
}

class PlatformTimeLimitWarningEvent {
  PlatformTimeLimitWarningEvent({required this.remainingMinutes});

  int remainingMinutes;
}

class PlatformStreamsSuspendingEvent {
  PlatformStreamsSuspendingEvent({
    required this.streamIds,
    required this.reason,
  });

  List<String> streamIds;
  String reason;
}

class PlatformBackgroundTaskExtendedEvent {
  PlatformBackgroundTaskExtendedEvent({
    required this.streamIds,
    required this.estimatedTime,
  });

  List<String> streamIds;
  int estimatedTime;
}

class PlatformAppIntentImagePayload {
  PlatformAppIntentImagePayload({required this.filename, required this.bytes});

  String filename;
  Uint8List bytes;
}

class PlatformAppIntentResponse {
  PlatformAppIntentResponse({required this.success, this.value, this.error});

  bool success;
  String? value;
  String? error;
}

class PlatformNativePasteImageItem {
  PlatformNativePasteImageItem({required this.mimeType, required this.data});

  String mimeType;
  Uint8List data;
}

class PlatformNativePastePayload {
  PlatformNativePastePayload({required this.kind, this.text, this.items});

  PlatformNativePasteKind kind;
  String? text;
  List<PlatformNativePasteImageItem>? items;
}

class PlatformKeyboardAttachmentActionConfig {
  PlatformKeyboardAttachmentActionConfig({
    required this.id,
    required this.label,
    this.subtitle,
    required this.sfSymbol,
    required this.section,
    required this.enabled,
    required this.selected,
    required this.dismissesKeyboard,
  });

  String id;
  String label;
  String? subtitle;
  String sfSymbol;
  String section;
  bool enabled;
  bool selected;
  bool dismissesKeyboard;
}

class PlatformKeyboardAttachmentConfig {
  PlatformKeyboardAttachmentConfig({required this.actions});

  List<PlatformKeyboardAttachmentActionConfig> actions;
}

class PlatformKeyboardAttachmentActionEvent {
  PlatformKeyboardAttachmentActionEvent({required this.id});

  String id;
}

class PlatformKeyboardAttachmentVisibilityEvent {
  PlatformKeyboardAttachmentVisibilityEvent({required this.visible});

  bool visible;
}

class PlatformRect {
  PlatformRect({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  double x;
  double y;
  double width;
  double height;
}

class PlatformDropdownOption {
  PlatformDropdownOption({
    required this.id,
    required this.label,
    this.subtitle,
    this.sfSymbol,
    required this.enabled,
    required this.destructive,
  });

  String id;
  String label;
  String? subtitle;
  String? sfSymbol;
  bool enabled;
  bool destructive;
}

class PlatformDropdownRequest {
  PlatformDropdownRequest({
    this.title,
    this.message,
    this.cancelLabel,
    required this.options,
    this.sourceRect,
  });

  String? title;
  String? message;
  String? cancelLabel;
  List<PlatformDropdownOption> options;
  PlatformRect? sourceRect;
}

class PlatformNativeSheetOption {
  PlatformNativeSheetOption({
    required this.id,
    required this.label,
    this.subtitle,
    this.sfSymbol,
    required this.enabled,
    required this.destructive,
    required this.ancestorHasMoreSiblings,
    required this.showBranch,
    required this.hasMoreSiblings,
  });

  String id;
  String label;
  String? subtitle;
  String? sfSymbol;
  bool enabled;
  bool destructive;
  List<bool> ancestorHasMoreSiblings;
  bool showBranch;
  bool hasMoreSiblings;
}

class PlatformNativeSheetItem {
  PlatformNativeSheetItem({
    required this.id,
    required this.title,
    this.subtitle,
    required this.sfSymbol,
    required this.destructive,
    this.url,
    required this.kind,
    this.value,
    this.placeholder,
    required this.options,
    this.sourceIndex,
    this.sourceUrl,
    this.sourceType,
    this.snippet,
    this.faviconUrl,
    required this.queries,
    required this.links,
    required this.pending,
    this.min,
    this.max,
    this.divisions,
  });

  String id;
  String title;
  String? subtitle;
  String sfSymbol;
  bool destructive;
  String? url;
  PlatformNativeSheetItemKind kind;
  Object? value;
  String? placeholder;
  List<PlatformNativeSheetOption> options;
  int? sourceIndex;
  String? sourceUrl;
  String? sourceType;
  String? snippet;
  String? faviconUrl;
  List<String> queries;
  List<PlatformNativeSheetLink> links;
  bool pending;
  double? min;
  double? max;
  int? divisions;
}

class PlatformNativeSheetLink {
  PlatformNativeSheetLink({required this.url, this.title, this.faviconUrl});

  String url;
  String? title;
  String? faviconUrl;
}

class PlatformNativeSheetSection {
  PlatformNativeSheetSection({this.title, this.footer, required this.items});

  String? title;
  String? footer;
  List<PlatformNativeSheetItem> items;
}

class PlatformNativeEditProfileSheetConfig {
  PlatformNativeEditProfileSheetConfig({
    required this.title,
    required this.saveLabel,
    required this.cancelLabel,
    required this.okLabel,
    required this.footerText,
    required this.nameLabel,
    required this.nameRequiredMessage,
    required this.customGenderRequiredMessage,
    required this.bioLabel,
    required this.bioHint,
    required this.genderLabel,
    required this.genderPreferNotToSay,
    required this.genderMale,
    required this.genderFemale,
    required this.genderCustom,
    required this.customGenderLabel,
    required this.customGenderHint,
    required this.birthDateLabel,
    required this.selectBirthDateLabel,
    required this.clearLabel,
    required this.uploadFromDeviceLabel,
    required this.useInitialsLabel,
    required this.removeAvatarLabel,
    required this.currentAvatarLabel,
  });

  String title;
  String saveLabel;
  String cancelLabel;
  String okLabel;
  String footerText;
  String nameLabel;
  String nameRequiredMessage;
  String customGenderRequiredMessage;
  String bioLabel;
  String bioHint;
  String genderLabel;
  String genderPreferNotToSay;
  String genderMale;
  String genderFemale;
  String genderCustom;
  String customGenderLabel;
  String customGenderHint;
  String birthDateLabel;
  String selectBirthDateLabel;
  String clearLabel;
  String uploadFromDeviceLabel;
  String useInitialsLabel;
  String removeAvatarLabel;
  String currentAvatarLabel;
}

class PlatformNativeProfileSheetUser {
  PlatformNativeProfileSheetUser({
    required this.displayName,
    required this.email,
    required this.initials,
    this.avatarUrl,
    this.avatarBytes,
    required this.avatarHeaders,
    this.bio,
    this.gender,
    this.dateOfBirth,
    this.profileImageUrl,
  });

  String displayName;
  String email;
  String initials;
  String? avatarUrl;
  Uint8List? avatarBytes;
  Map<String, String> avatarHeaders;
  String? bio;
  String? gender;
  String? dateOfBirth;
  String? profileImageUrl;
}

class PlatformNativeSheetDetail {
  PlatformNativeSheetDetail({
    required this.id,
    required this.title,
    this.subtitle,
    required this.items,
    required this.sections,
    this.confirmActionId,
    this.confirmActionLabel,
    this.maxHeightFraction,
  });

  String id;
  String title;
  String? subtitle;
  List<PlatformNativeSheetItem> items;
  List<PlatformNativeSheetSection> sections;
  String? confirmActionId;
  String? confirmActionLabel;
  double? maxHeightFraction;
}

class PlatformNativeProfileSheetConfig {
  PlatformNativeProfileSheetConfig({
    required this.profile,
    this.profileMenuTitle,
    required this.editProfileLabel,
    this.editProfileSheet,
    this.supportTitle,
    this.supportSubtitle,
    required this.menuItems,
    required this.supportItems,
    required this.sections,
    required this.detailSheets,
  });

  PlatformNativeProfileSheetUser profile;
  String? profileMenuTitle;
  String editProfileLabel;
  PlatformNativeEditProfileSheetConfig? editProfileSheet;
  String? supportTitle;
  String? supportSubtitle;
  List<PlatformNativeSheetItem> menuItems;
  List<PlatformNativeSheetItem> supportItems;
  List<PlatformNativeSheetSection> sections;
  List<PlatformNativeSheetDetail> detailSheets;
}

class PlatformNativeSheetModelOption {
  PlatformNativeSheetModelOption({
    required this.id,
    required this.name,
    this.subtitle,
    this.sfSymbol,
    this.avatarUrl,
    required this.avatarHeaders,
    required this.tags,
  });

  String id;
  String name;
  String? subtitle;
  String? sfSymbol;
  String? avatarUrl;
  Map<String, String> avatarHeaders;
  List<String> tags;
}

class PlatformNativeSheetModelSelectorRequest {
  PlatformNativeSheetModelSelectorRequest({
    required this.title,
    this.selectedModelId,
    required this.models,
    required this.pinnedModelIds,
    required this.allowsPinning,
    this.pinTitle,
    this.unpinTitle,
  });

  String title;
  String? selectedModelId;
  List<PlatformNativeSheetModelOption> models;
  List<String> pinnedModelIds;
  bool allowsPinning;
  String? pinTitle;
  String? unpinTitle;
}

class PlatformNativeSheetOptionsSelectorRequest {
  PlatformNativeSheetOptionsSelectorRequest({
    required this.title,
    this.subtitle,
    this.selectedOptionId,
    required this.searchable,
    required this.options,
  });

  String title;
  String? subtitle;
  String? selectedOptionId;
  bool searchable;
  List<PlatformNativeSheetOption> options;
}

class PlatformNativeSheetDatePickerRequest {
  PlatformNativeSheetDatePickerRequest({
    required this.title,
    required this.initialDateIso8601,
    required this.firstDateIso8601,
    required this.lastDateIso8601,
    this.doneLabel,
    this.cancelLabel,
  });

  String title;
  String initialDateIso8601;
  String firstDateIso8601;
  String lastDateIso8601;
  String? doneLabel;
  String? cancelLabel;
}

class PlatformNativeSheetTextEditorRequest {
  PlatformNativeSheetTextEditorRequest({
    required this.title,
    required this.value,
    this.placeholder,
    this.sendLabel,
    required this.valueId,
    required this.sendActionId,
    required this.closeActionId,
  });

  String title;
  String value;
  String? placeholder;
  String? sendLabel;
  String valueId;
  String sendActionId;
  String closeActionId;
}

class PlatformNativeSheetResultRequest {
  PlatformNativeSheetResultRequest({
    required this.root,
    required this.detailSheets,
  });

  PlatformNativeSheetDetail root;
  List<PlatformNativeSheetDetail> detailSheets;
}

class PlatformNativeSheetApplyDetailPatchRequest {
  PlatformNativeSheetApplyDetailPatchRequest({
    required this.detailId,
    required this.items,
    this.title,
    this.subtitle,
    this.detailSheets,
  });

  String detailId;
  List<PlatformNativeSheetItem> items;
  String? title;
  String? subtitle;
  List<PlatformNativeSheetDetail>? detailSheets;
}

class PlatformNativeSheetControlChangedEvent {
  PlatformNativeSheetControlChangedEvent({required this.id, this.value});

  String id;
  Object? value;
}

class PlatformNativeSheetDetailAppearedEvent {
  PlatformNativeSheetDetailAppearedEvent({required this.detailId});

  String detailId;
}

class PlatformNativeSheetModelPinToggledEvent {
  PlatformNativeSheetModelPinToggledEvent({required this.modelId});

  String modelId;
}

class PlatformNativeEditProfileCommittedEvent {
  PlatformNativeEditProfileCommittedEvent({
    required this.name,
    required this.profileImageUrl,
    required this.bio,
    this.gender,
    this.dateOfBirth,
  });

  String name;
  String profileImageUrl;
  String bio;
  String? gender;
  String? dateOfBirth;
}

class PlatformNativeSheetActionResult {
  PlatformNativeSheetActionResult({
    required this.actionId,
    required this.values,
  });

  String actionId;
  Map<String, Object?> values;
}

@HostApi()
abstract class BackgroundStreamingHostApi {
  void startBackgroundExecution(PlatformBackgroundStartRequest request);
  void stopBackgroundExecution(PlatformBackgroundStopRequest request);
  void keepAlive(PlatformBackgroundKeepAliveRequest request);
  bool checkBackgroundRefreshStatus();
  bool checkNotificationPermission();
  void setExternalAudioSessionOwner(
    PlatformBackgroundAudioSessionOwnerRequest request,
  );
  int getActiveStreamCount();
  List<PlatformBackgroundStreamLease> getActiveStreamLeases();
  void stopAllBackgroundExecution();
}

@FlutterApi()
abstract class BackgroundStreamingFlutterApi {
  int checkStreams();
  void streamsSuspending(PlatformStreamsSuspendingEvent event);
  void backgroundTaskExpiring();
  void backgroundTaskExtended(PlatformBackgroundTaskExtendedEvent event);
  void backgroundKeepAlive();
  void serviceFailed(PlatformServiceFailureEvent event);
  void timeLimitApproaching(PlatformTimeLimitWarningEvent event);
  void microphonePermissionFallback();
}

@FlutterApi()
abstract class AppIntentFlutterApi {
  @async
  PlatformAppIntentResponse askChat(String? prompt);

  @async
  PlatformAppIntentResponse startVoiceCall();

  @async
  PlatformAppIntentResponse sendText(String text);

  @async
  PlatformAppIntentResponse sendUrl(String url);

  @async
  PlatformAppIntentResponse sendImage(PlatformAppIntentImagePayload payload);
}

@HostApi()
abstract class NativePasteHostApi {
  bool requestPaste();
}

@FlutterApi()
abstract class NativePasteFlutterApi {
  void onPaste(PlatformNativePastePayload payload);
}

@HostApi()
abstract class NativeKeyboardAttachmentHostApi {
  void configure(PlatformKeyboardAttachmentConfig config);
  bool toggle(PlatformKeyboardAttachmentConfig config);
  void hide();
}

@FlutterApi()
abstract class NativeKeyboardAttachmentFlutterApi {
  void onAction(PlatformKeyboardAttachmentActionEvent event);
  void onVisibilityChanged(PlatformKeyboardAttachmentVisibilityEvent event);
}

@HostApi()
abstract class NativeDropdownHostApi {
  @async
  String? show(PlatformDropdownRequest request);
}

@HostApi()
abstract class NativeSheetHostApi {
  @async
  bool presentProfileMenu(PlatformNativeProfileSheetConfig config);

  bool dismiss();

  @async
  String? presentModelSelector(PlatformNativeSheetModelSelectorRequest request);

  @async
  String? presentOptionsSelector(
    PlatformNativeSheetOptionsSelectorRequest request,
  );

  @async
  String? presentDatePicker(PlatformNativeSheetDatePickerRequest request);

  @async
  PlatformNativeSheetActionResult? presentTextEditor(
    PlatformNativeSheetTextEditorRequest request,
  );

  @async
  PlatformNativeSheetActionResult? presentResultSheet(
    PlatformNativeSheetResultRequest request,
  );

  bool applyDetailPatch(PlatformNativeSheetApplyDetailPatchRequest request);
}

@FlutterApi()
abstract class NativeSheetFlutterApi {
  void onDismissed();
  void onLogoutRequested();
  void onControlChanged(PlatformNativeSheetControlChangedEvent event);
  void onDetailAppeared(PlatformNativeSheetDetailAppearedEvent event);
  void onModelPinToggled(PlatformNativeSheetModelPinToggledEvent event);
  void commitEditProfile(PlatformNativeEditProfileCommittedEvent event);
}
