import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  WorkspaceToolSummary parse(Map<String, dynamic> extra) =>
      WorkspaceToolSummary.fromJson({
        'id': 't-1',
        'name': 'Search',
        'user_id': 'owner',
        'specs': [
          {'name': 'search'},
        ],
        ...extra,
      });

  group('a tool switched on or off (Open WebUI 0.13)', () {
    test('reads the switch only from a server that reports it', () {
      expect(parse({'is_active': true}).isActive, isTrue);
      expect(parse({'is_active': false}).isActive, isFalse);
      // Older servers have no switch; every tool is on there.
      expect(parse(const {}).isActive, isNull);
    });
  });
}
