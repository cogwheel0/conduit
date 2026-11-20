import 'dart:async';

import 'package:conduit_core/ports/location_port.dart';
import 'package:conduit_core/services/location_service.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:riverpod/misc.dart' show Override;

import 'event_bus.dart';

/// The Mac's location services, for `{{USER_LOCATION}}`: the core's
/// [LocationPort], answered by the window (CoreLocation is the app's, not
/// this process's).
///
/// Each port call is one `location.command` the window answers with a
/// `location.report` naming it. The core decides when to ask
/// ([LocationLookupPolicy.whenNamedAndAllowed]): only for a request or a
/// prompt template that names the variable, and only while the account's
/// location setting is on. With no window to answer, or none in time,
/// location services read as off and the core falls back to the place the
/// user typed (or none).
final class WindowLocationBridge implements LocationPort {
  WindowLocationBridge({
    Duration timeout = const Duration(seconds: 10),
    Duration permissionTimeout = const Duration(seconds: 60),
  }) : _timeout = timeout,
       _permissionTimeout = permissionTimeout;

  final Duration _timeout;

  /// The system's permission prompt waits for the user.
  final Duration _permissionTimeout;
  EventBus? _events;
  int _nextId = 0;
  final Map<int, Completer<LocationReport>> _pending =
      <int, Completer<LocationReport>>{};

  /// How many commands went to the window, by kind (for tests and the
  /// log): a request that never names the variable adds none.
  final Map<LocationCommandKind, int> sent = <LocationCommandKind, int>{};

  void bind(EventBus events) => _events = events;

  /// The window's answer to a command.
  void report(LocationReport report) {
    final waiting = _pending.remove(report.id);
    if (waiting != null && !waiting.isCompleted) waiting.complete(report);
  }

  @override
  Future<bool> isLocationServiceEnabled() async {
    try {
      final report = await _command(LocationCommandKind.status);
      return report.servicesEnabled ?? false;
    } on StateError {
      return false;
    }
  }

  @override
  Future<LocationPermissionStatus> checkPermission() async {
    try {
      final report = await _command(LocationCommandKind.status);
      return _status(report.permission);
    } on StateError {
      return LocationPermissionStatus.denied;
    }
  }

  @override
  Future<LocationPermissionStatus> requestPermission() async {
    try {
      final report = await _command(
        LocationCommandKind.requestPermission,
        timeout: _permissionTimeout,
      );
      return _status(report.permission);
    } on StateError {
      return LocationPermissionStatus.denied;
    }
  }

  @override
  Future<LocationFix> currentPosition() async {
    final report = await _command(LocationCommandKind.currentPosition);
    final latitude = report.latitude;
    final longitude = report.longitude;
    if (latitude == null || longitude == null) {
      throw StateError('the window sent no position');
    }
    return LocationFix(latitude: latitude, longitude: longitude);
  }

  static LocationPermissionStatus _status(LocationPermission? permission) =>
      switch (permission) {
        LocationPermission.whileInUse => LocationPermissionStatus.whileInUse,
        LocationPermission.always => LocationPermissionStatus.always,
        LocationPermission.deniedForever =>
          LocationPermissionStatus.deniedForever,
        LocationPermission.unableToDetermine =>
          LocationPermissionStatus.unableToDetermine,
        LocationPermission.denied || null => LocationPermissionStatus.denied,
      };

  /// Sends a command and waits for its answer; throws [StateError] when no
  /// window answers, it refuses, or none answers in time.
  Future<LocationReport> _command(
    LocationCommandKind kind, {
    Duration? timeout,
  }) async {
    final events = _events;
    if (events == null) throw StateError('no window yet');
    final id = ++_nextId;
    final completer = Completer<LocationReport>();
    _pending[id] = completer;
    try {
      final reached = events.emit(
        ConduitEventSpecs.locationCommand,
        LocationCommand(id: id, kind: kind),
      );
      if (reached == 0) throw StateError('no window to ask ${kind.name}');
      sent[kind] = (sent[kind] ?? 0) + 1;
      final report = await completer.future.timeout(timeout ?? _timeout);
      if (!report.ok) {
        throw StateError(report.error ?? '${kind.name} failed');
      }
      return report;
    } on TimeoutException {
      throw StateError('the window did not answer ${kind.name}');
    } finally {
      _pending.remove(id);
    }
  }
}

/// The core's location service over [bridge], asking only when a prompt
/// names `{{USER_LOCATION}}` and the account's setting allows it.
List<Override> windowLocationOverrides(WindowLocationBridge bridge) =>
    <Override>[
      locationServiceProvider.overrideWithValue(
        LocationService(
          port: bridge,
          policy: LocationLookupPolicy.whenNamedAndAllowed,
        ),
      ),
    ];
