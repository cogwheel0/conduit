import 'package:freezed_annotation/freezed_annotation.dart';

part 'webhooks.freezed.dart';
part 'webhooks.g.dart';

/// One webhook destination of the account, as Open WebUI lists it. The
/// server never returns the URL; [maskedUrl] is for display only.
@freezed
abstract class WebhookDto with _$WebhookDto {
  const factory WebhookDto({
    required String id,
    @Default(true) bool enabled,
    @Default(false) bool isDefault,

    /// Subscribed event ids, kept verbatim.
    @Default(<String>[]) List<String> events,

    /// `away` or `always`, as the server sent it.
    @Default('away') String delivery,
    String? maskedUrl,
  }) = _WebhookDto;

  factory WebhookDto.fromJson(Map<String, dynamic> json) =>
      _$WebhookDtoFromJson(json);
}

/// One event a destination can subscribe to.
@freezed
abstract class WebhookEventDto with _$WebhookEventDto {
  const factory WebhookEventDto({
    required String event,
    required String label,
    String? description,
  }) = _WebhookEventDto;

  factory WebhookEventDto.fromJson(Map<String, dynamic> json) =>
      _$WebhookEventDtoFromJson(json);
}

/// Reply to `webhooks.list` and every change: the destinations and the
/// events they can subscribe to.
@freezed
abstract class WebhookList with _$WebhookList {
  const factory WebhookList({
    /// The account may manage destinations (the server has them on and the
    /// account is an admin or holds `features.webhooks`).
    @Default(false) bool available,

    /// Names the account the list was read for. Every change sends it back,
    /// and is refused once another account is signed in.
    @Default('') String owner,
    @Default(<WebhookDto>[]) List<WebhookDto> items,
    @Default(<WebhookEventDto>[]) List<WebhookEventDto> events,

    /// A change went through, but reading the list back failed.
    @Default(false) bool stale,

    /// The list could not be read.
    @Default(false) bool failed,
  }) = _WebhookList;

  factory WebhookList.fromJson(Map<String, dynamic> json) =>
      _$WebhookListFromJson(json);
}

/// Params for `webhooks.create`.
@freezed
abstract class WebhookCreate with _$WebhookCreate {
  const factory WebhookCreate({
    required String owner,
    required String url,

    /// The destination's name (its id); the server derives one when empty.
    @Default('') String name,
    @Default(true) bool enabled,
    @Default(<String>[]) List<String> events,
    @Default('away') String delivery,
  }) = _WebhookCreate;

  factory WebhookCreate.fromJson(Map<String, dynamic> json) =>
      _$WebhookCreateFromJson(json);
}

/// Params for `webhooks.update`: only what changed. A URL goes out only as
/// a replacement the user typed.
@freezed
abstract class WebhookUpdate with _$WebhookUpdate {
  const factory WebhookUpdate({
    required String owner,
    required String id,
    bool? enabled,
    List<String>? events,
    String? delivery,
    String? url,
  }) = _WebhookUpdate;

  factory WebhookUpdate.fromJson(Map<String, dynamic> json) =>
      _$WebhookUpdateFromJson(json);
}

/// Params for `webhooks.makeDefault`, `webhooks.test` and `webhooks.delete`.
@freezed
abstract class WebhookRef with _$WebhookRef {
  const factory WebhookRef({required String owner, required String id}) =
      _WebhookRef;

  factory WebhookRef.fromJson(Map<String, dynamic> json) =>
      _$WebhookRefFromJson(json);
}
