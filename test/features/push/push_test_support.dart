import 'package:conduit_core/features/hermes/models/hermes_config.dart';
import 'package:conduit_core/features/push/models/push_status.dart';
import 'package:conduit_core/features/push/models/push_target.dart';
import 'package:conduit_core/features/push/providers/push_providers.dart';
import 'package:conduit_core/ports/push_platform_port.dart';
import 'package:conduit_core/services/settings_service.dart';

const pushOwuiTarget = OpenWebUiPushTarget(
  accountId: 'acct-1',
  label: 'ada@example.com',
);
const pushHermesApiTarget = HermesPushTarget(
  connectionId: 'conn-api',
  label: 'Home Hermes',
  baseUrl: 'https://hermes.example',
  mode: HermesBackendMode.responsesApi,
);
const pushHermesDesktopTarget = HermesPushTarget(
  connectionId: 'conn-desk',
  label: 'Desk Hermes',
  baseUrl: 'https://desk.example',
  mode: HermesBackendMode.desktopGateway,
);

/// Push state with [targets] on, as the relay-backed iOS build sees it.
PushState pushStateWith(
  List<PushTargetState> targets, {
  bool enabled = true,
  bool permissionDenied = false,
  bool relayConfigured = true,
  List<PushTransport> transports = const [PushTransport.apns],
  PushAndroidTransport? androidTransport,
}) => PushState(
  enabled: enabled,
  relayConfigured: relayConfigured,
  availableTransports: transports,
  transportsChecked: true,
  permissionDenied: permissionDenied,
  androidTransport: androidTransport,
  targets: {for (final target in targets) target.scope: target},
);

/// A push coordinator that records what the UI asks of it.
final class FakePushCoordinator extends PushCoordinator {
  FakePushCoordinator(this.initial, {this.distributorList = const []});

  final PushState initial;
  final List<String> distributorList;
  final calls = <String>[];
  bool testArrives = true;

  /// Thrown by [setEnabled] after [setEnabledDelay], once the switch shows
  /// the new value.
  Object? setEnabledError;
  Duration setEnabledDelay = Duration.zero;

  @override
  PushState build() => initial;

  void emit(PushState next) => state = next;

  @override
  Future<void> setEnabled(bool enabled) async {
    calls.add('setEnabled $enabled');
    state = state.copyWith(enabled: enabled);
    if (setEnabledDelay > Duration.zero) {
      await Future<void>.delayed(setEnabledDelay);
    }
    final error = setEnabledError;
    if (error != null) throw error;
  }

  @override
  Future<bool> installOpenWebUiFunction(String scope) async {
    calls.add('installOpenWebUiFunction $scope');
    return true;
  }

  @override
  Future<bool> installHermesPlugin(String scope) async {
    calls.add('installHermesPlugin $scope');
    return true;
  }

  @override
  Future<bool> sendTest(String scope) async {
    calls.add('sendTest $scope');
    return testArrives;
  }

  @override
  Future<void> retry(String scope) async => calls.add('retry $scope');

  @override
  Future<void> setOrigin(String scope, PushOrigin origin) async {
    calls.add('setOrigin $scope ${origin.name}');
    final target = state.targets[scope]!;
    state = state.copyWith(
      targets: {
        ...state.targets,
        scope: target.copyWith(origin: origin),
      },
    );
  }

  @override
  Future<void> setTargetOptedOut(String scope, bool optedOut) async {
    calls.add('setTargetOptedOut $scope $optedOut');
    final target = state.targets[scope]!;
    state = state.copyWith(
      targets: {
        ...state.targets,
        scope: target.copyWith(optedOut: optedOut),
      },
    );
  }

  @override
  Future<void> resetKeys() async => calls.add('resetKeys');

  @override
  Future<void> setAndroidTransport(
    PushAndroidTransport? transport, {
    String? distributor,
  }) async {
    calls.add('setAndroidTransport ${transport?.name} $distributor');
    state = state.copyWith(
      androidTransport: transport,
      clearAndroidTransport: transport == null,
      distributor: distributor,
    );
  }

  @override
  Future<List<String>> distributors() async => distributorList;

  /// Thrown by [setHermesJobNotify].
  Object? jobNotifyError;

  @override
  Future<String> setHermesJobNotify({
    required String connectionId,
    required String jobId,
    required bool notify,
  }) async {
    calls.add('setHermesJobNotify $connectionId $jobId $notify');
    final error = jobNotifyError;
    if (error != null) throw error;
    return notify ? 'local,conduit' : 'local';
  }
}

final class FixedSettings extends AppSettingsNotifier {
  FixedSettings(this.settings);

  final AppSettings settings;

  @override
  AppSettings build() => settings;
}
