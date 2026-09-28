import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:jaspr_riverpod/jaspr_riverpod.dart';

import 'rpc_providers.dart';

/// Every Hermes call the window makes, in one place so a test
/// replaces the daemon by overriding this.
final hermesActionsProvider = Provider<HermesActions>(HermesActions.new);

class HermesActions {
  HermesActions(this._ref);

  final Ref _ref;

  Future<T> _call<T>(
    String method,
    Map<String, dynamic>? params,
    T Function(Map<String, dynamic>) decode,
  ) =>
      _ref.read(rpcClientProvider).call(method, params: params, decode: decode);

  Future<HermesSettings> settings() =>
      _call(ConduitMethods.hermesSettings, null, HermesSettings.fromJson);

  Future<HermesSettings> save(HermesSettingsEdit edit) => _call(
    ConduitMethods.hermesSaveSettings,
    edit.toJson(),
    HermesSettings.fromJson,
  );

  Future<HermesTestResult> test(HermesSettingsEdit edit) => _call(
    ConduitMethods.hermesTest,
    edit.toJson(),
    HermesTestResult.fromJson,
  );

  Future<HermesStatus> status() =>
      _call(ConduitMethods.hermesStatus, null, HermesStatus.fromJson);

  Future<HermesSettings> signIn() =>
      _call(ConduitMethods.hermesSignIn, null, HermesSettings.fromJson);

  Future<HermesSettings> signOut() =>
      _call(ConduitMethods.hermesSignOut, null, HermesSettings.fromJson);

  Future<HermesSessions> sessions() =>
      _call(ConduitMethods.hermesSessions, null, HermesSessions.fromJson);

  Future<HermesSessions> rename(String id, String title) => _call(
    ConduitMethods.hermesRenameSession,
    HermesRename(id: id, title: title).toJson(),
    HermesSessions.fromJson,
  );

  Future<HermesSessions> delete(String id) => _call(
    ConduitMethods.hermesDeleteSession,
    HermesRef(id: id).toJson(),
    HermesSessions.fromJson,
  );

  Future<HermesSessionDto> fork(String id) => _call(
    ConduitMethods.hermesForkSession,
    HermesRef(id: id).toJson(),
    HermesSessionDto.fromJson,
  );

  Future<HermesJobs> jobs() =>
      _call(ConduitMethods.hermesJobs, null, HermesJobs.fromJson);

  Future<HermesJobs> saveJob(HermesJobEdit edit) =>
      _call(ConduitMethods.hermesSaveJob, edit.toJson(), HermesJobs.fromJson);

  Future<HermesJobs> setJobEnabled(String id, {required bool enabled}) => _call(
    ConduitMethods.hermesSetJobEnabled,
    HermesJobToggle(id: id, enabled: enabled).toJson(),
    HermesJobs.fromJson,
  );

  Future<HermesJobs> runJob(String id) => _call(
    ConduitMethods.hermesRunJob,
    HermesRef(id: id).toJson(),
    HermesJobs.fromJson,
  );

  Future<HermesJobs> deleteJob(String id) => _call(
    ConduitMethods.hermesDeleteJob,
    HermesRef(id: id).toJson(),
    HermesJobs.fromJson,
  );

  Future<HermesCatalog> catalog() =>
      _call(ConduitMethods.hermesCatalog, null, HermesCatalog.fromJson);
}

/// Ticks on `hermes.changed`: settings, sessions or jobs moved.
final _hermesChangedProvider = StreamProvider<int>((ref) {
  var tick = 0;
  return ref
      .watch(rpcClientProvider)
      .events
      .where((envelope) => envelope.event == ConduitEvents.hermesChanged)
      .map((_) => ++tick);
});

final hermesSettingsProvider = FutureProvider<HermesSettings>((ref) {
  ref.watch(coreConnectionProvider);
  ref.watch(_hermesChangedProvider);
  return ref.read(hermesActionsProvider).settings();
});

final hermesStatusProvider = FutureProvider<HermesStatus>((ref) {
  ref.watch(hermesSettingsProvider);
  return ref.read(hermesActionsProvider).status();
});

final hermesSessionsProvider = FutureProvider<HermesSessions>((ref) {
  ref.watch(coreConnectionProvider);
  ref.watch(_hermesChangedProvider);
  return ref.read(hermesActionsProvider).sessions();
});

final hermesJobsProvider = FutureProvider<HermesJobs>((ref) {
  ref.watch(coreConnectionProvider);
  ref.watch(_hermesChangedProvider);
  return ref.read(hermesActionsProvider).jobs();
});

final hermesCatalogProvider = FutureProvider<HermesCatalog>((ref) {
  ref.watch(hermesSettingsProvider);
  return ref.read(hermesActionsProvider).catalog();
});
