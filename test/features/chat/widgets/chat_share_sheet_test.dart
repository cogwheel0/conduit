import 'package:checks/checks.dart';
import 'package:conduit/core/models/conversation.dart';
import 'package:conduit/core/models/server_config.dart';
import 'package:conduit/core/providers/app_providers.dart';
import 'package:conduit/core/services/api_service.dart';
import 'package:conduit/core/services/worker_manager.dart';
import 'package:conduit/features/auth/providers/unified_auth_providers.dart';
import 'package:conduit/features/chat/widgets/chat_share_sheet.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:share_plus/share_plus.dart';

class _RecordingShareApiService extends ApiService {
  _RecordingShareApiService()
    : super(
        serverConfig: const ServerConfig(
          id: 'test',
          name: 'Test',
          url: 'https://example.com',
        ),
        workerManager: WorkerManager(),
      );

  int shareCalls = 0;

  @override
  Future<String?> shareConversation(String id) async {
    shareCalls += 1;
    return 'share-$shareCalls';
  }

  @override
  Future<List<Conversation>> getConversationPage({
    int page = 1,
    bool includeFolders = true,
    bool includePinned = false,
  }) async {
    return const <Conversation>[];
  }

  @override
  Future<List<Conversation>> getPinnedChats() async {
    return const <Conversation>[];
  }

  @override
  Future<List<Conversation>> getArchivedChats({int? limit, int? offset}) async {
    return const <Conversation>[];
  }
}

class _TestConversations extends Conversations {
  @override
  Future<List<Conversation>> build() async => const <Conversation>[];

  @override
  Future<void> refresh({
    bool includeFolders = false,
    bool forceFresh = false,
  }) async {}
}

class _RecordingShareAction {
  int shareCalls = 0;
  String? lastText;

  Future<ShareResult> share(ShareParams params) async {
    shareCalls += 1;
    lastText = params.text;
    return const ShareResult('success', ShareResultStatus.success);
  }
}

void main() {
  setUp(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (
          MethodCall methodCall,
        ) async {
          if (methodCall.method == 'Clipboard.setData') {
            return null;
          }
          return null;
        });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  testWidgets('copying an existing share re-snapshots every time', (
    tester,
  ) async {
    final api = _RecordingShareApiService();
    final conversation = Conversation(
      id: 'chat-1',
      title: 'Shared chat',
      createdAt: DateTime.utc(2026, 4, 26),
      updatedAt: DateTime.utc(2026, 4, 26),
      shareId: 'existing-share',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          conversationsProvider.overrideWith(_TestConversations.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: ChatShareSheet(conversation: conversation)),
        ),
      ),
    );

    await tester.tap(find.text('Update and Copy Link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    await tester.tap(find.text('Update and Copy Link'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    check(api.shareCalls).equals(2);
  });

  testWidgets('platform share uses the latest re-snapshotted URL', (
    tester,
  ) async {
    final api = _RecordingShareApiService();
    final shareAction = _RecordingShareAction();
    final conversation = Conversation(
      id: 'chat-1',
      title: 'Shared chat',
      createdAt: DateTime.utc(2026, 4, 26),
      updatedAt: DateTime.utc(2026, 4, 26),
      shareId: 'existing-share',
    );

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          isAuthenticatedProvider2.overrideWithValue(true),
          apiServiceProvider.overrideWithValue(api),
          conversationsProvider.overrideWith(_TestConversations.new),
        ],
        child: MaterialApp(
          theme: AppTheme.light(TweakcnThemes.t3Chat),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: ChatShareSheet(
              conversation: conversation,
              share: shareAction.share,
            ),
          ),
        ),
      ),
    );

    await tester.tap(find.text('Share...'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    check(api.shareCalls).equals(1);
    check(shareAction.shareCalls).equals(1);
    check(shareAction.lastText).equals('https://example.com/s/share-1');
  });
}
