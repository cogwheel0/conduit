import 'package:conduit/features/workspace/widgets/workspace_resource_presentation.dart';
import 'package:conduit/l10n/app_localizations_en.dart';
import 'package:conduit_core/features/workspace/models/workspace_resources.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final l10n = AppLocalizationsEn();

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

    test('a tool switched off reads as inactive in the list', () {
      expect(
        presentWorkspaceTool(l10n, parse({'is_active': false})).statusLabel,
        l10n.inactiveStatus,
      );
      expect(
        presentWorkspaceTool(l10n, parse({'is_active': true})).statusLabel,
        l10n.workspaceToolFunctionCount(1),
      );
      expect(
        presentWorkspaceTool(l10n, parse(const {})).statusLabel,
        l10n.workspaceToolFunctionCount(1),
      );
    });
  });
}
