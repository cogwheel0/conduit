import 'package:freezed_annotation/freezed_annotation.dart';

part 'notifications.freezed.dart';
part 'notifications.g.dart';

/// The notification settings (`notifications.get`, `notifications.set`), as
/// the phone's Notifications page shows them. [enabled], [sound] and
/// [soundAlways] are mirrored to the Open WebUI account when one is signed
/// in ([synced]); the rest stay on this Mac.
@freezed
abstract class NotificationSettingsDto with _$NotificationSettingsDto {
  const factory NotificationSettingsDto({
    /// The master toggle.
    @Default(false) bool enabled,
    @Default(true) bool sound,

    /// The cue plays for every alert, the in-app banner's too.
    @Default(false) bool soundAlways,
    @Default(true) bool inAppBanner,
    @Default(true) bool system,

    /// An answer finished in a chat the user is not looking at.
    @Default(true) bool answers,

    /// Someone else posted in a channel or a direct message.
    @Default(true) bool channels,

    /// With [channels], only mentions and direct messages alert.
    @Default(false) bool mentionsOnly,

    /// The first three are mirrored to an Open WebUI account.
    @Default(false) bool synced,
  }) = _NotificationSettingsDto;

  factory NotificationSettingsDto.fromJson(Map<String, dynamic> json) =>
      _$NotificationSettingsDtoFromJson(json);
}

/// Params for `notifications.set`: only the fields given change.
@freezed
abstract class NotificationSettingsPatch with _$NotificationSettingsPatch {
  const factory NotificationSettingsPatch({
    bool? enabled,
    bool? sound,
    bool? soundAlways,
    bool? inAppBanner,
    bool? system,
    bool? answers,
    bool? channels,
    bool? mentionsOnly,
  }) = _NotificationSettingsPatch;

  factory NotificationSettingsPatch.fromJson(Map<String, dynamic> json) =>
      _$NotificationSettingsPatchFromJson(json);
}

/// What a notification is about.
enum NotifyKind {
  /// An answer finished (or failed).
  answer,

  /// Someone else posted in a channel or a direct message.
  channelMessage,
}

/// Where a notification goes.
enum NotifySurface { banner, system, silent, suppressed }

/// Params for `notifications.route`: one notification and what the window
/// knows about it.
@freezed
abstract class NotificationRouteParams with _$NotificationRouteParams {
  const factory NotificationRouteParams({
    required NotifyKind kind,

    /// The app is in front (active).
    @Default(false) bool foreground,

    /// The user is looking at the notification's chat or channel.
    @Default(false) bool viewing,

    /// A channel message alerts by its channel's own setting
    /// ([ChannelPosted.alert]).
    @Default(true) bool alert,

    /// A channel message mentions the user.
    @Default(false) bool mention,

    /// A channel message is a direct message.
    @Default(false) bool direct,
  }) = _NotificationRouteParams;

  factory NotificationRouteParams.fromJson(Map<String, dynamic> json) =>
      _$NotificationRouteParamsFromJson(json);
}

/// `notifications.answered`: an Open WebUI answer this Mac did not run
/// finished (on another device, or a scheduled task's run), as the
/// phone's notification listener hears it on the server's socket
/// (`chat:completion`, its last frame). The window routes it as it routes
/// `turn.finished` (`notifications.route`, an answer).
@freezed
abstract class AnswerNotice with _$AnswerNotice {
  const factory AnswerNotice({
    required String chatId,

    /// The answer's message id, when the server names it.
    @Default('') String messageId,

    /// The chat's title as the server sent it; may be empty.
    @Default('') String title,
  }) = _AnswerNotice;

  factory AnswerNotice.fromJson(Map<String, dynamic> json) =>
      _$AnswerNoticeFromJson(json);
}

/// Reply to `notifications.route`: the core's decision.
@freezed
abstract class NotificationRoute with _$NotificationRoute {
  const factory NotificationRoute({
    @Default(NotifySurface.suppressed) NotifySurface surface,

    /// Play the notification cue.
    @Default(false) bool cue,

    /// The system notification makes its sound.
    @Default(false) bool systemSound,
  }) = _NotificationRoute;

  factory NotificationRoute.fromJson(Map<String, dynamic> json) =>
      _$NotificationRouteFromJson(json);
}
