import 'package:conduit_core/providers/app_providers.dart';

import 'dart:async';

export 'hermes_task_receipts.dart';

import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/hermes/services/hermes_desktop_api_service.dart';
import 'package:conduit_core/features/hermes/services/hermes_identifier.dart';
import 'package:conduit_core/models/prompt.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Mounted by Tasks only. Listing work does not activate a session or
/// acknowledge approvals; those interactions belong to the open chat.
final hermesMobileActiveTasksProvider =
    FutureProvider.autoDispose<List<Map<String, dynamic>>>((ref) async {
      final service = ref.watch(hermesApiServiceProvider);
      if (service is! HermesDesktopApiService) return const [];
      final observedAt = DateTime.now().millisecondsSinceEpoch;
      final rows = await service.listActiveSessions().timeout(
        const Duration(seconds: 12),
      );
      if (!ref.mounted) return const [];
      // Poll after completion. Invalidating during the request can leave
      // slow gateways permanently loading.
      final timer = Timer(const Duration(seconds: 15), ref.invalidateSelf);
      ref.onDispose(timer.cancel);
      return rows
          .where((row) {
            return const {
              'starting',
              'waiting',
              'working',
              'streaming',
              'resuming',
            }.contains(row['status']);
          })
          .map((row) => {...row, '_conduitObservedAt': observedAt})
          .toList(growable: false);
    });

/// Discovery contains installed skills, rather than every raw slash command.
final hermesMobileSkillsProvider = FutureProvider.autoDispose<List<Prompt>>((
  ref,
) {
  final service = ref.watch(hermesApiServiceProvider);
  if (service == null) return const [];
  List<Prompt> prompts(List<Map<String, dynamic>> skills) => [
    for (final row in skills.take(256))
      if (validateHermesOpaqueIdentifier(row['name']) case final String name)
        Prompt(
          command: '/$name',
          title: row['description']?.toString() ?? '',
          content: '/$name ',
          meta: {'hermesSkillCategory': row['category']},
        ),
  ];
  final cached = service is HermesDesktopApiService
      ? service.cachedSkillCatalog
      : null;
  return cached == null ? service.listSkills().then(prompts) : prompts(cached);
});

/// Never substitutes the connection's default profile for an owned bot session.
final hermesCallSkillsProvider = FutureProvider.autoDispose<List<Prompt>>((
  ref,
) async {
  final service = ref.watch(hermesApiServiceProvider);
  final conversation = ref.watch(activeConversationProvider);
  if (service == null) return const [];
  final session = conversation?.metadata['hermesSessionId']?.toString();
  final rows = service is HermesDesktopApiService && session != null
      ? await service.listCallSkills(session)
      : await service.listSkills();
  return [
    for (final row in rows)
      if (validateHermesOpaqueIdentifier(row['name']) case final String name)
        Prompt(
          command: '/$name',
          title: row['description']?.toString() ?? '',
          content: name,
        ),
  ];
});
