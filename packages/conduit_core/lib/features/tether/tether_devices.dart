import 'dart:async';

import 'package:riverpod/riverpod.dart';

import 'package:conduit_core/features/terminal/providers/terminal_providers.dart';
import 'package:conduit_core/features/tools/providers/tools_providers.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/utils/debug_logger.dart';

/// Counts the times the user's Tether devices changed what they offer the
/// signed-in Open WebUI server (0.13.4 and later). It moves on once the
/// models, tools and terminals were read again, so a host that waits for it
/// shows the new lists.
final tetherDevicesProvider = NotifierProvider<TetherDevices, int>(
  TetherDevices.new,
);

class TetherDevices extends Notifier<int> {
  @override
  int build() => 0;

  /// A device connected, left, was renamed or changed what it offers
  /// (Open WebUI's `terminals:changed`): the server lists its models, tools
  /// and terminals among its own, so all three are read again, the
  /// terminals an open chat's scope holds included.
  Future<void> changed() async {
    ref.read(terminalsChangedProvider.notifier).changed();
    Future<void> refresh(String list, Future<void> Function() read) async {
      try {
        await read();
      } catch (error, stackTrace) {
        DebugLogger.error(
          'refresh-failed',
          scope: 'tether/$list',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }

    await Future.wait(<Future<void>>[
      refresh('models', ref.read(modelsProvider.notifier).refresh),
      refresh('tools', ref.read(toolsListProvider.notifier).refresh),
    ]);
    if (ref.mounted) state++;
  }
}
