import 'dart:async';

import 'package:checks/checks.dart';
import 'package:conduit/core/services/native_sheet_bridge.dart';
import 'package:conduit/features/navigation/widgets/sidebar_user_pill.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/platform/conduit_platform_apis.g.dart';
import 'package:conduit/platform/flutter_key_value_store.dart';
import 'package:conduit/shared/services/navigation_service.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit_core/features/automations/providers/automation_providers.dart'
    show scheduledTasksEntryVisibleProvider;
import 'package:conduit_core/features/calendar/providers/calendar_providers.dart'
    show calendarAvailableProvider;
import 'package:conduit_core/features/chat/providers/chat_providers.dart'
    show chatDataControlsEntryVisibleProvider;
import 'package:conduit_core/features/hermes/providers/hermes_providers.dart';
import 'package:conduit_core/features/integrations/providers/personal_connections_providers.dart';
import 'package:conduit_core/features/workspace/models/workspace_capabilities.dart';
import 'package:conduit_core/features/workspace/providers/workspace_capabilities_provider.dart';
import 'package:conduit_core/models/account_metadata.dart';
import 'package:conduit_core/models/user.dart';
import 'package:conduit_core/persistence/preferences_store.dart';
import 'package:conduit_core/providers/app_providers.dart';
import 'package:conduit_core/services/optimized_storage_service.dart';
import 'package:conduit_core/services/settings_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockOptimizedStorageService extends Mock
    implements OptimizedStorageService {}

const _ada = User(
  id: 'user-1',
  username: 'ada',
  email: 'ada@example.com',
  name: 'Ada',
  role: 'user',
);

AccountMetadata _profile({String id = 'user-1', String? bio}) =>
    AccountMetadata(
      id: id,
      email: 'ada@example.com',
      name: 'Ada',
      role: 'user',
      isActive: true,
      bio: bio,
      gender: 'female',
      dateOfBirth: '1990-01-01',
      profileImageUrl: '/avatar.png',
    );

/// An account profile whose refresh finishes when the test says so.
class _Profiles extends AccountProfile {
  _Profiles(this._cached);

  final AccountMetadata? _cached;
  Completer<AccountMetadata?>? pending;
  var refreshes = 0;

  @override
  Future<AccountMetadata?> build() async => _cached;

  @override
  Future<void> refresh() async {
    refreshes++;
    final next = pending = Completer<AccountMetadata?>();
    state = const AsyncLoading();
    state = AsyncData(await next.future);
  }
}

class _SignedInUser extends Notifier<User?> {
  @override
  User? build() => _ada;

  void signIn(User? user) => state = user;
}

final _signedInUser = NotifierProvider<_SignedInUser, User?>(
  _SignedInUser.new,
);

final _applyDetailPatchChannel = BasicMessageChannel<Object?>(
  'dev.flutter.pigeon.conduit.NativeSheetHostApi.applyDetailPatch',
  NativeSheetHostApi.pigeonChannelCodec,
);

const _nativeSheetChannel = MethodChannel(
  NativeSheetBridge.nativeSheetChannelName,
);

final class _Harness {
  _Harness(this.container, this.profiles);

  final ProviderContainer container;
  final _Profiles profiles;
  final presented = <NativeProfileSheetConfig>[];
  final profileUpdates = <Map<Object?, Object?>>[];
  final patches = <PlatformNativeSheetApplyDetailPatchRequest>[];
}

Future<_Harness> _pump(
  WidgetTester tester, {
  required AccountMetadata? cached,
}) async {
  final storage = _MockOptimizedStorageService();
  when(storage.getThemeMode).thenReturn(null);
  when(storage.getThemePaletteId).thenReturn(null);
  when(storage.getLocaleCode).thenReturn(null);
  when(storage.getReviewerMode).thenAnswer((_) async => false);
  final profiles = _Profiles(cached);
  late final _Harness harness;
  final container = ProviderContainer(
    overrides: [
      optimizedStorageServiceProvider.overrideWithValue(storage),
      appSettingsProvider.overrideWithValue(const AppSettings()),
      apiServiceProvider.overrideWithValue(null),
      currentUserProvider2.overrideWith((ref) => ref.watch(_signedInUser)),
      currentUserProvider.overrideWith((ref) async => ref.watch(_signedInUser)),
      hermesOnlyModeProvider.overrideWithValue(false),
      accountProfileProvider.overrideWith(() => profiles),
      workspaceCapabilitiesProvider.overrideWith(
        (ref) => Completer<WorkspaceCapabilities>().future,
      ),
      calendarAvailableProvider.overrideWithValue(false),
      scheduledTasksEntryVisibleProvider.overrideWithValue(false),
      personalConnectionsEntryVisibleProvider.overrideWithValue(false),
      chatDataControlsEntryVisibleProvider.overrideWithValue(false),
      sidebarNativeProfilePresenterProvider.overrideWithValue((config) async {
        harness.presented.add(config);
        return true;
      }),
    ],
  );
  addTearDown(container.dispose);
  harness = _Harness(container, profiles);

  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  messenger
    ..setMockMethodCallHandler(_nativeSheetChannel, (call) async {
      harness.profileUpdates.add(call.arguments as Map<Object?, Object?>);
      return true;
    })
    ..setMockDecodedMessageHandler<Object?>(_applyDetailPatchChannel, (
      message,
    ) async {
      harness.patches.add(
        (message! as List<Object?>).single!
            as PlatformNativeSheetApplyDetailPatchRequest,
      );
      return <Object?>[true];
    });

  await container.read(accountProfileProvider.future);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: NavigationService.navigatorKey,
        theme: AppTheme.light(TweakcnThemes.t3Chat),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const Scaffold(body: SidebarProfileAppBarLeading()),
      ),
    ),
  );
  await tester.pump();
  return harness;
}

Future<void> _tapAvatar(WidgetTester tester) async {
  await tester.tap(find.byKey(const ValueKey('sidebar-profile-button')));
  await tester.pump();
  await tester.pump();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    PreferencesStore.debugOverride(await FlutterKeyValueStore.load());
    NativeSheetBridge.instance.debugIsIOSOverride = true;
  });

  tearDown(() {
    PreferencesStore.debugReset();
    NativeSheetBridge.instance.debugIsIOSOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      ..setMockMethodCallHandler(_nativeSheetChannel, null)
      ..setMockDecodedMessageHandler<Object?>(_applyDetailPatchChannel, null);
  });

  testWidgets('a cached profile opens the sheet before the refresh returns, '
      'and a changed profile is handed to it afterwards', (tester) async {
    final harness = await _pump(tester, cached: _profile(bio: 'Old'));

    await _tapAvatar(tester);

    // Opened at once on the cached copy while the refresh is still out.
    check(harness.presented).length.equals(1);
    check(harness.profiles.refreshes).equals(1);
    check(harness.presented.single.profile.bio).equals('Old');
    check(harness.profileUpdates).isEmpty();

    harness.profiles.pending!.complete(_profile(bio: 'New'));
    await tester.pump();
    await tester.pump();

    check(harness.profileUpdates).length.equals(1);
    check(harness.profileUpdates.single['bio']).equals('New');
    check(harness.profileUpdates.single['gender']).equals('female');
    final profilePage = harness.patches.lastWhere(
      (patch) => patch.detailId == NativeSheetRoutes.profile,
    );
    final about = [
      for (final section in profilePage.sections) ...section.items,
    ].singleWhere((item) => item.id == 'profile-about');
    check(about.subtitle).equals('New');
  });

  testWidgets('an unchanged profile leaves the sheet alone', (tester) async {
    final harness = await _pump(tester, cached: _profile(bio: 'Same'));

    await _tapAvatar(tester);
    harness.profiles.pending!.complete(_profile(bio: 'Same'));
    await tester.pump();
    await tester.pump();

    check(harness.presented).length.equals(1);
    check(harness.profileUpdates).isEmpty();
    check(
      harness.patches.where((p) => p.detailId == NativeSheetRoutes.profile),
    ).isEmpty();
  });

  testWidgets('a refresh that lands after another account signed in is '
      'dropped', (tester) async {
    final harness = await _pump(tester, cached: _profile(bio: 'Old'));

    await _tapAvatar(tester);
    harness.container
        .read(_signedInUser.notifier)
        .signIn(_ada.copyWith(id: 'user-2', email: 'grace@example.com'));
    harness.profiles.pending!.complete(
      _profile(id: 'user-2', bio: 'Grace'),
    );
    await tester.pump();
    await tester.pump();

    check(harness.profileUpdates).isEmpty();
    check(
      harness.patches.where((p) => p.detailId == NativeSheetRoutes.profile),
    ).isEmpty();
  });

  testWidgets('with no cached profile the sheet waits for the profile to '
      'load', (tester) async {
    final harness = await _pump(tester, cached: null);

    await _tapAvatar(tester);
    check(harness.presented).isEmpty();

    harness.profiles.pending!.complete(_profile(bio: 'Loaded'));
    await tester.pump();
    await tester.pump();

    check(harness.presented).length.equals(1);
    check(harness.presented.single.profile.bio).equals('Loaded');
    // It opened on the fresh copy, so there is nothing to hand it later.
    check(harness.profiles.refreshes).equals(1);
    check(harness.profileUpdates).isEmpty();
  });
}
