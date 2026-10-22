import 'package:conduit_core/features/hermes/services/hermes_run_transport.dart';
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';

import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/hermes/providers/hermes_workspace.dart';
import '../features/hermes/providers/hermes_messages.dart';

/// Read-only verification through the app's normal authenticated service.
/// The response contains support flags and counts, never tokens or file contents.
class HermesWorkspaceProbe {
  static const enabled = bool.fromEnvironment('CONDUIT_WORKSPACE_PROBE');
  static void install(ProviderContainer container) {
    if (!enabled) return;
    developer.registerExtension('ext.conduit.hermesWorkspace', (
      _,
      parameters,
    ) async {
      final service = container.read(hermesWorkspaceServiceProvider);
      final backend = container.read(hermesMessagesBackendProvider);
      if (service == null || backend == null) {
        return developer.ServiceExtensionResponse.error(
          -32000,
          'Hermes workspace unavailable',
        );
      }
      try {
        final capabilities = await service.groupCapabilities().timeout(
          const Duration(seconds: 20),
        );
        final bots = await backend.listBots().timeout(
          const Duration(seconds: 20),
        );
        final groups = await backend.listBotGroups().timeout(
          const Duration(seconds: 20),
        );
        final profiles = <Map<String, Object?>>[];
        for (final bot in bots.take(6)) {
          final row = <String, Object?>{'profile': bot.name};
          Future<void> check(
            String name,
            Future<Object?> Function() request,
          ) async {
            try {
              final result = await request().timeout(
                const Duration(seconds: 15),
              );
              row[name] = result is List
                  ? result.length
                  : result is String
                  ? result.length
                  : result is bool
                  ? result
                  : result != null;
            } catch (error) {
              row[name] = 'unavailable';
              row['${name}Error'] = error.runtimeType.toString();
              row['${name}Reason'] = sanitizeHermesProviderErrorMessage(
                error.toString(),
                sensitiveValues:
                    container
                        .read(hermesApiServiceProvider)
                        ?.config
                        .sensitiveValues ??
                    const [],
                maxCharacters: 180,
              );
            }
          }

          await check('identity', () => service.describeBot(bot.name));
          await check('home', () => service.botHome(bot.name));
          await check('workspace', () => service.botWorkspace(bot.name));
          await check('memory', () => service.readBotMemory(bot.name));
          await check(
            'userMemory',
            () => service.readBotMemory(bot.name, aboutUser: true),
          );
          await check('models', () => service.botModels(bot.name));
          await check('ready', () => service.botProviderReady(bot.name));
          profiles.add(row);
        }
        return developer.ServiceExtensionResponse.result(
          jsonEncode({
            'driver': capabilities['driver'] == true,
            'persistentProcess': capabilities['persistent_process'] == true,
            'methods': capabilities['methods'],
            'bots': bots.length,
            'groups': groups.length,
            'profiles': profiles,
          }),
        );
      } catch (error) {
        return developer.ServiceExtensionResponse.error(
          -32000,
          error.runtimeType.toString(),
        );
      }
    });
  }
}
