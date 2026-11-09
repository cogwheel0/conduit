import 'dart:io';

import 'package:conduit/features/chat/widgets/model_selector_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/database_provider.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/direct_connections/models/direct_connection_profile.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_connection_providers.dart';
import 'package:conduit_core/features/librechat/models/librechat_model.dart';
import 'package:conduit_core/models/conversation.dart';
import 'package:conduit_core/models/model.dart';
import 'package:conduit_core/models/server_user_settings.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:drift/native.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey, MethodChannel;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';

class _NoActive extends ActiveConversationNotifier {
  @override
  Conversation? build() => null;
}

class _FixedPersonalization extends PersonalizationSettings {
  @override
  Future<ServerUserSettings> build() async => const ServerUserSettings();
}

class _EmptySelected extends SelectedModel {
  @override
  Model? build() => null;
}

class _NoProfiles extends DirectConnectionProfilesController {
  @override
  Future<List<DirectConnectionProfile>> build() async => const [];
}

/// The section titles in the more-models list fold their section away, and
/// a screen reader or a keyboard can do that as well as a tap.
void main() {
  late AppDatabase db;

  setUp(() {
    db = AppDatabase(NativeDatabase.memory());
    // Model rows draw an avatar through a cache that asks for a temp folder.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          (call) async => Directory.systemTemp.path,
        );
  });
  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('plugins.flutter.io/path_provider'),
          null,
        );
    await db.close();
  });

  Future<ProviderContainer> openMoreModels(WidgetTester tester) async {
    // The first four models are featured; the rest of the second endpoint
    // lands in its own section under more models.
    final models = libreChatCatalog(
      startupConfig: const <String, dynamic>{},
      endpoints: const <String, dynamic>{
        'Alpha': <String, dynamic>{'order': 0},
        'Bravo': <String, dynamic>{'order': 1},
      },
      models: const <String, List<String>>{
        'Alpha': <String>['alpha-one', 'alpha-two', 'alpha-three'],
        'Bravo': <String>['bravo-one', 'bravo-two', 'bravo-three'],
      },
    );
    final container = ProviderContainer(
      overrides: [
        appDatabaseProvider.overrideWith((ref) => db),
        apiServiceProvider.overrideWithValue(null),
        selectedModelProvider.overrideWith(_EmptySelected.new),
        activeConversationProvider.overrideWith(_NoActive.new),
        personalizationSettingsProvider.overrideWith(_FixedPersonalization.new),
        directConnectionProfilesProvider.overrideWith(_NoProfiles.new),
        isAuthenticatedProvider2.overrideWithValue(false),
      ],
    );
    addTearDown(container.dispose);
    // Tall enough for the whole picker, with more models in view.
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: conduitLocalizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ModelSelectorSheet(models: models)),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('More Models'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('bravo-two'), findsOneWidget);
    return container;
  }

  testWidgets('a screen reader hears a section title as one button it can '
      'press', (tester) async {
    final semantics = tester.ensureSemantics();
    await openMoreModels(tester);

    final title = find.bySemanticsLabel('Bravo');
    expect(
      tester.getSemantics(title),
      isSemantics(
        label: 'Bravo',
        isButton: true,
        hasExpandedState: true,
        isExpanded: true,
        isFocusable: true,
        hasTapAction: true,
      ),
    );

    tester.semantics.tap(find.semantics.byLabel('Bravo'));
    await tester.pump();
    expect(find.text('bravo-two'), findsNothing);
    expect(
      tester.getSemantics(title),
      isSemantics(hasExpandedState: true, isExpanded: false),
    );
    semantics.dispose();
  });

  testWidgets('a keyboard folds and opens a section', (tester) async {
    await openMoreModels(tester);

    Focus.of(tester.element(find.text('Bravo'))).requestFocus();
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(find.text('bravo-two'), findsNothing);

    await tester.sendKeyEvent(LogicalKeyboardKey.space);
    await tester.pump();
    expect(find.text('bravo-two'), findsOneWidget);
  });
}
