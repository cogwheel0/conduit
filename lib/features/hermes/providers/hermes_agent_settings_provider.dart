import 'package:conduit_core/features/hermes/models/hermes_agent_settings.dart';
import 'package:conduit_core/features/hermes/models/hermes_model.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// A profile-scoped settings capability, replaced when connections change.
abstract interface class HermesAgentSettingsAccess {
  Future<HermesAgentSettings> agentSettings();
  Future<void> setModelEnsembles(
    Map<String, dynamic> settings,
    Map<String, dynamic> expected,
  );
  Future<List<HermesDesktopModelOption>> configuredModels();
  Future<void> setAgentSetting(HermesSettingField field, Object? value);
  Future<void> setDefaultModel(HermesDesktopModelOption model, {String? task});
  Future<void> resetAuxiliaryModel(String task);
  Future<void> useGlobalModel(String task);
  Future<void> setAuxiliaryReasoning({
    required String task,
    required String provider,
    required String model,
    String? effort,
    String? baseUrl,
  });
  Future<void> setFallbackModels(
    List<Map<String, dynamic>> models,
    Object? expected,
  );
}

class _DesktopSettingsAccess implements HermesAgentSettingsAccess {
  const _DesktopSettingsAccess(this.service);
  final HermesDesktopApiService service;
  @override
  Future<void> setModelEnsembles(
    Map<String, dynamic> settings,
    Map<String, dynamic> expected,
  ) => service.setModelEnsembles(settings, expected);
  @override
  Future<HermesAgentSettings> agentSettings() => service.agentSettings();
  @override
  Future<List<HermesDesktopModelOption>> configuredModels() =>
      service.configuredModels();
  @override
  Future<void> setAgentSetting(HermesSettingField field, Object? value) =>
      service.setAgentSetting(field, value);
  @override
  Future<void> setDefaultModel(
    HermesDesktopModelOption model, {
    String? task,
  }) => service.setDefaultModel(model, task: task);
  @override
  Future<void> setAuxiliaryReasoning({
    required String task,
    required String provider,
    required String model,
    String? effort,
    String? baseUrl,
  }) => service.setAuxiliaryReasoning(
    task: task,
    provider: provider,
    model: model,
    effort: effort,
    baseUrl: baseUrl,
  );
  @override
  Future<void> resetAuxiliaryModel(String task) =>
      service.resetAuxiliaryModel(task);
  @override
  Future<void> useGlobalModel(String task) => service.useGlobalModel(task);
  @override
  Future<void> setFallbackModels(
    List<Map<String, dynamic>> models,
    Object? expected,
  ) => service.setFallbackModels(models, expected);
}

final hermesAgentSettingsAccessProvider = Provider<HermesAgentSettingsAccess?>((
  ref,
) {
  final service = ref.watch(hermesApiServiceProvider);
  return service is HermesDesktopApiService
      ? _DesktopSettingsAccess(service)
      : null;
});
final hermesAgentSettingsProvider =
    FutureProvider.autoDispose<HermesAgentSettings?>((ref) async {
      return ref.watch(hermesAgentSettingsAccessProvider)?.agentSettings();
    });
