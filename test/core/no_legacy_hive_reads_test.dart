/// CDT-RFC-001 §11 Phase 1 acceptance (b): no production code path reads the
/// legacy Hive `local_conversations` / `local_folders` caches. The deleted
/// accessors (`getLocalConversations`, `getLocalFolders`, and their save
/// counterparts) must not reappear anywhere under lib/.
library;

import 'dart:io';

import 'package:checks/checks.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('lib/ contains no legacy conversation/folder cache accessors', () {
    final pattern = RegExp(
      r'getLocalConversations|getLocalFolders|'
      r'saveLocalConversations|saveLocalFolders',
    );
    final offenders = <String>[];
    for (final entity in Directory('lib').listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) {
        continue;
      }
      final lines = entity.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (pattern.hasMatch(lines[i])) {
          offenders.add('${entity.path}:${i + 1}: ${lines[i].trim()}');
        }
      }
    }
    check(
      because:
          'Phase 1 acceptance: no code path may read or write the legacy '
          'Hive local_conversations/local_folders caches',
      offenders,
    ).isEmpty();
  });
}
