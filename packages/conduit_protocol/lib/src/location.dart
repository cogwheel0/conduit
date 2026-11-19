import 'package:freezed_annotation/freezed_annotation.dart';

part 'location.freezed.dart';
part 'location.g.dart';

/// What `location.command` asks the window's location services for: the
/// core's location port, one method each (the phone's port asks its OS the
/// same four things).
///
/// The daemon asks only for a request or a prompt that names
/// `{{USER_LOCATION}}`, and only while the account's location setting is on
/// (the core's `LocationLookupPolicy`); nothing else reaches the window.
enum LocationCommandKind {
  /// Whether location services are on, and what this app may do: answered
  /// with [LocationReport.servicesEnabled] and [LocationReport.permission].
  /// Never asks the user anything.
  status,

  /// Asks for permission (the system's prompt, the first time): answered
  /// with [LocationReport.permission] once the user chose.
  requestPermission,

  /// One position fix: answered with [LocationReport.latitude] and
  /// [LocationReport.longitude], or `ok` false.
  currentPosition,
}

/// Payload of `location.command`. Answered with `location.report` naming
/// [id].
@freezed
abstract class LocationCommand with _$LocationCommand {
  const factory LocationCommand({
    required int id,
    required LocationCommandKind kind,
  }) = _LocationCommand;

  factory LocationCommand.fromJson(Map<String, dynamic> json) =>
      _$LocationCommandFromJson(json);
}

/// What the app may do with the location, as the core's port says it.
enum LocationPermission {
  denied,
  deniedForever,
  whileInUse,
  always,
  unableToDetermine,
}

/// Params for `location.report`: the window's answer to a command.
@freezed
abstract class LocationReport with _$LocationReport {
  const factory LocationReport({
    required int id,

    /// Whether the command was carried out; [error] says why not, for the
    /// log.
    @Default(true) bool ok,
    String? error,

    /// `status`: whether location services are on for this Mac.
    bool? servicesEnabled,

    /// `status` and `requestPermission`.
    LocationPermission? permission,

    /// `currentPosition`, in degrees.
    double? latitude,
    double? longitude,
  }) = _LocationReport;

  factory LocationReport.fromJson(Map<String, dynamic> json) =>
      _$LocationReportFromJson(json);
}
