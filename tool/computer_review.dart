// Synthetic local review harness. Production Computer widgets, real terminal.
import 'package:conduit/features/terminal/widgets/computer_launcher.dart';
import 'package:conduit/l10n/app_localizations.dart';
import 'package:conduit/l10n/conduit_localizations.dart';
import 'package:conduit/shared/theme/app_theme.dart';
import 'package:conduit/shared/theme/tweakcn_themes.dart';
import 'package:conduit_core/features/terminal/models/terminal_models.dart';
import 'package:conduit_core/features/chat/providers/chat_providers.dart';
import 'package:conduit_core/models/chat_message.dart';
import 'package:conduit_core/features/terminal/providers/computer_providers.dart';
import 'package:conduit_core/features/terminal/services/computer_service.dart';
import 'package:conduit_core/features/terminal/services/terminal_service.dart';
import 'package:conduit_core/models/server_config.dart';
import 'package:conduit_core/services/api_service.dart';
import 'package:conduit_core/services/worker_manager.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

void main() {
  const url = String.fromEnvironment(
    'COMPUTER_REVIEW_URL',
    defaultValue: 'http://127.0.0.1:18768',
  );
  final terminal = TerminalService(
    ApiService(
      serverConfig: const ServerConfig(id: 'review', name: 'Review', url: url),
      workerManager: WorkerManager(),
    ),
  );
  final service = ComputerService(
    terminal,
    TerminalServerInfo(
      kind: TerminalServerKind.direct,
      selectionId: 'review',
      baseUrl: Uri.parse(url),
      apiKey: 'computer-review-only',
      name: 'Creative workspace',
    ),
    'computer-review',
  );
  runApp(
    ProviderScope(
      overrides: [
        chatMessagesProvider.overrideWith(_ReviewMessages.new),
        computerServiceProvider.overrideWith((ref) async => service),
        computerTakeControlProvider.overrideWithValue(() async {
          await Dio().post<void>('http://127.0.0.1:8767/pause');
          return true;
        }),
      ],
      child: MaterialApp(
        debugShowCheckedModeBanner: false,
        theme: AppTheme.light(TweakcnThemes.conduit),
        localizationsDelegates: conduitLocalizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: const _ReviewChat(),
      ),
    ),
  );
}

class _ReviewChat extends StatelessWidget {
  const _ReviewChat();

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      leading: const Icon(Icons.menu_rounded),
      title: const Text('Weekend workshop'),
      actions: [
        IconButton(onPressed: () {}, icon: const Icon(Icons.edit_square)),
      ],
    ),
    body: SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Expanded(
              child: SingleChildScrollView(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 24),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        constraints: const BoxConstraints(maxWidth: 320),
                        padding: const EdgeInsets.all(16),
                        decoration: BoxDecoration(
                          color: const Color(0xfff1f1f1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'Put together a creative weekend workshop board.',
                          style: TextStyle(fontSize: 16, height: 1.5),
                        ),
                      ),
                    ),
                    const SizedBox(height: 28),
                    const Text(
                      'I’ll bring the ideas together in the workspace. You can open the computer to follow along or make a change.',
                      style: TextStyle(fontSize: 16, height: 1.7),
                    ),
                    const SizedBox(height: 20),
                    Row(
                      children: [
                        const Icon(Icons.auto_awesome_outlined, size: 16),
                        const SizedBox(width: 9),
                        const Expanded(
                          child: Text(
                            'Preparing the workshop board',
                            style: TextStyle(
                              fontSize: 13,
                              color: Color(0xff7a7a7a),
                            ),
                          ),
                        ),
                        IconButton(
                          tooltip: 'Run synthetic task',
                          onPressed: () =>
                              Dio().post<void>('http://127.0.0.1:8767/run'),
                          icon: const Icon(Icons.play_arrow_rounded, size: 20),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 12),
            const ComputerLauncher(),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              decoration: BoxDecoration(
                color: const Color(0xfff5f5f5),
                borderRadius: BorderRadius.circular(28),
              ),
              child: const Row(
                children: [
                  Icon(Icons.add_rounded, size: 22),
                  SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      'Message',
                      style: TextStyle(color: Color(0xff999999)),
                    ),
                  ),
                  Icon(Icons.mic_none_rounded, size: 22),
                ],
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

class _ReviewMessages extends ChatMessagesNotifier {
  @override
  List<ChatMessage> build() => [];
}
