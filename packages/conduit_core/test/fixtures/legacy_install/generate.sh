#!/usr/bin/env bash
# Regenerates v3.3.1/conduit_hive: the Hive boxes a v3.3.1 install leaves in
# <Documents>/conduit_hive (the last release that kept preferences in Hive;
# v3.4.0 moved them to shared_preferences through HivePrefsMigrator).
#
# The boxes are written with hive_ce 2.14.0, the version v2.0.0 first shipped
# (v3.3.1 shipped 2.19.3; the frame format is the same), in a throwaway
# package outside the workspace so the pinned version cannot leak into it.
# The values mirror what v3.3.1 stores: typed preferences, server-scoped cache
# envelopes ({data, serverId}), the JSON user cache, one failed upload and
# migration_version 1. One value is synthetic: v3.3.1 kept no Map-valued
# preference, so server_feature_availability_v1 (a later key) stands in for
# one and exercises HivePrefsMigrator's Map-to-JSON branch.
# legacy_install_fixture_test.dart reads the boxes.
#
#   packages/conduit_core/test/fixtures/legacy_install/generate.sh
set -euo pipefail

here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
out="$here/v3.3.1/conduit_hive"
work="$(mktemp -d "${TMPDIR:-/tmp}/conduit-legacy-hive.XXXXXX")"
trap 'rm -rf "$work"' EXIT

cat > "$work/pubspec.yaml" <<'YAML'
name: conduit_legacy_hive_fixture
publish_to: none
environment:
  sdk: ^3.5.0
dependencies:
  hive_ce: 2.14.0
YAML

mkdir -p "$work/bin"
cat > "$work/bin/generate.dart" <<'DART'
import 'dart:io';

import 'package:hive_ce/hive.dart';

Future<void> main(List<String> args) async {
  final out = Directory(args.single);
  if (out.existsSync()) out.deleteSync(recursive: true);
  out.createSync(recursive: true);
  Hive.init(out.path);

  final preferences = await Hive.openBox<dynamic>('preferences_v1');
  await preferences.putAll(<String, dynamic>{
    'active_server_id': 'server-a',
    'haptic_feedback': true,
    'locale_code_v1': 'de',
    'pinned_models': <String>['llama3:8b', 'gpt-4o'],
    'reviewer_mode_v1': false,
    'server_feature_availability_v1': <String, dynamic>{
      'server-a': <String, dynamic>{'notes': true, 'channels': false},
    },
    'theme_mode': 'dark',
    'theme_palette_v1': 'ocean',
    'tts_speech_rate': 0.9,
    'voice_silence_duration': 1500,
  });

  final caches = await Hive.openBox<dynamic>('caches_v1');
  await caches.putAll(<String, dynamic>{
    'local_backend_config': <String, dynamic>{
      'data': <String, dynamic>{'version': '0.6.5', 'enableWebsocket': true},
      'serverId': 'server-a',
    },
    'local_models': <String, dynamic>{
      'data': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'llama3:8b', 'name': 'Llama 3'},
      ],
      'serverId': 'server-a',
    },
    'local_tools': <String, dynamic>{
      'data': <Map<String, dynamic>>[
        <String, dynamic>{'id': 'tool-b'},
      ],
      'serverId': 'server-b',
    },
    'local_transport_options': <String, dynamic>{
      'data': <String, dynamic>{
        'allowPolling': true,
        'allowWebsocketOnly': false,
      },
      'serverId': 'server-a',
    },
    'local_user': '{"id":"user-1","name":"Legacy User"}',
    'local_user_avatar': '/user.png',
  });

  final attachmentQueue = await Hive.openBox<dynamic>('attachment_queue_v1');
  await attachmentQueue.put('attachment_queue_entries', <Map<String, dynamic>>[
    <String, dynamic>{
      'id': 'att-1',
      'filePath': '/var/mobile/tmp/photo.jpg',
      'fileName': 'photo.jpg',
      'fileSize': 2048,
      'mimeType': 'image/jpeg',
      'checksum': null,
      'enqueuedAt': '2026-01-15T10:00:00.000Z',
      'retryCount': 1,
      'nextRetryAt': null,
      'status': 'failed',
      'lastError': 'offline',
      'fileId': null,
    },
  ]);

  final metadata = await Hive.openBox<dynamic>('metadata_v1');
  await metadata.put('migration_version', 1);

  await Hive.close();
  // Hive leaves lock files beside the boxes; an install at rest has none.
  for (final lock in out.listSync().whereType<File>()) {
    if (lock.path.endsWith('.lock')) lock.deleteSync();
  }
}
DART

(cd "$work" && dart pub get >/dev/null && dart run bin/generate.dart "$out")
ls -l "$out"
