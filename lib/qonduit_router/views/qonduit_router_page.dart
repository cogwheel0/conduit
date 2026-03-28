import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import '../providers/qonduit_router_providers.dart';
import '../data/qonduit_router_log_stream_service.dart';
import '../services/qonduit_router_ready_notification_service.dart';
import 'package:qonduit/qonduit_router/models/qonduit_runtime_state.dart';
import 'package:qonduit/qonduit_router/providers/qonduit_runtime_providers.dart';

class QonduitRouterPage extends ConsumerStatefulWidget {
  const QonduitRouterPage({super.key});

  @override
  ConsumerState<QonduitRouterPage> createState() => _QonduitRouterPageState();
}

class _QonduitRouterPageState extends ConsumerState<QonduitRouterPage> {
  String? _selectedModel;
  final TextEditingController _contextController = TextEditingController();
  bool _busy = false;

  final List<String> _logLines = [];
  StreamSubscription<List<String>>? _logSubscription;
  bool _showLogs = false;

  late final QonduitRouterReadyNotificationService _notificationService;

  @override
  void initState() {
    super.initState();

    final apiClient = ref.read(qonduitRouterApiClientProvider);
    _notificationService = QonduitRouterReadyNotificationService(
      apiClient: apiClient,
      notifications: FlutterLocalNotificationsPlugin(),
    );

    Future.microtask(() async {
      await _notificationService.initialize();
      // keep test notification removed now
    });
  }

  @override
  void dispose() {
    _contextController.dispose();
    _logSubscription?.cancel();
    _notificationService.dispose();
    super.dispose();
  }

  void _startLogStream() {
    _logSubscription?.cancel();

    final apiClient = ref.read(qonduitRouterApiClientProvider);
    final logService = QonduitRouterLogStreamService(apiClient);

    void connect() {
      _logSubscription?.cancel();

      _logSubscription = logService.streamLogLines().listen(
            (lines) {
          if (!mounted) return;
          setState(() {
            _logLines
              ..clear()
              ..addAll(lines);
          });
        },
        onError: (_) async {
          if (!_showLogs || !mounted) return;
          await Future.delayed(const Duration(seconds: 2));
          if (_showLogs && mounted) {
            connect();
          }
        },
        onDone: () async {
          if (!_showLogs || !mounted) return;
          await Future.delayed(const Duration(seconds: 2));
          if (_showLogs && mounted) {
            connect();
          }
        },
        cancelOnError: false,
      );
    }

    connect();
  }

  Future<void> _launch() async {
    final model = _selectedModel;
    if (model == null || model.isEmpty) return;

    final ctx = int.tryParse(_contextController.text.trim()) ?? 32768;

    setState(() => _busy = true);
    try {
      await ref.read(qonduitRouterApiClientProvider).launchModel(
        model: model,
        contextSize: ctx,
      );

      ref.read(qonduitRuntimeStateProvider.notifier).setRuntime(
        model: model,
        contextSize: ctx,
      );

      ref.invalidate(qonduitRouterStatusProvider);
      _logSubscription?.cancel();
      _notificationService.startWatchingForReady();

      if (_showLogs) {
        Future.delayed(const Duration(seconds: 2), () {
          if (mounted && _showLogs) {
            _startLogStream();
          }
        });
      }

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Model launch requested')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _stop() async {
    setState(() => _busy = true);
    try {
      await ref.read(qonduitRouterApiClientProvider).stopModel();
      ref.invalidate(qonduitRouterStatusProvider);
      _notificationService.stopWatching();
      _logSubscription?.cancel();

      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Model stop requested')),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final modelsAsync = ref.watch(qonduitRouterModelsProvider);
    final suggestedCtxAsync = ref.watch(qonduitRouterSuggestedContextProvider);
    final statusAsync = ref.watch(qonduitRouterStatusProvider);

    suggestedCtxAsync.whenData((ctx) {
      if (_contextController.text.isEmpty) {
        _contextController.text = '$ctx';
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Qonduit Router')),
      body: RefreshIndicator(
        onRefresh: () async {
          ref.invalidate(qonduitRouterModelsProvider);
          ref.invalidate(qonduitRouterSuggestedContextProvider);
          ref.invalidate(qonduitRouterStatusProvider);
        },
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            statusAsync.when(
              data: (status) => Card(
                child: ListTile(
                  title: Text(status.running ? 'llama.cpp running' : 'llama.cpp stopped'),
                  subtitle: Text(
                    'WebUI: ${status.webuiBase}\nllama.cpp: ${status.llamaBase}',
                  ),
                ),
              ),
              loading: () => const Card(
                child: ListTile(title: Text('Loading status...')),
              ),
              error: (e, _) => Card(
                child: ListTile(title: Text('Status error: $e')),
              ),
            ),
            const SizedBox(height: 12),
            modelsAsync.when(
              data: (models) {
                if (_selectedModel == null && models.isNotEmpty) {
                  _selectedModel = models.first;
                }
                return DropdownButtonFormField<String>(
                  value: _selectedModel,
                  decoration: const InputDecoration(
                    labelText: 'Model',
                    border: OutlineInputBorder(),
                  ),
                  items: models
                      .map(
                        (m) => DropdownMenuItem<String>(
                      value: m,
                      child: Text(m, overflow: TextOverflow.ellipsis),
                    ),
                  )
                      .toList(),
                  onChanged: _busy ? null : (value) => setState(() => _selectedModel = value),
                );
              },
              loading: () => const LinearProgressIndicator(),
              error: (e, _) => Text('Model list error: $e'),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _contextController,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(
                labelText: 'Context size',
                border: OutlineInputBorder(),
                helperText: 'Uses server suggestion if left unchanged',
              ),
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: FilledButton(
                    onPressed: _busy ? null : _launch,
                    child: const Text('Launch llama.cpp'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _stop,
                    child: const Text('Stop llama.cpp'),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              title: const Text('Show live docker logs'),
              value: _showLogs,
              onChanged: (value) {
                setState(() => _showLogs = value);
                if (value) {
                  _startLogStream();
                } else {
                  _logSubscription?.cancel();
                }
              },
            ),
            if (_showLogs) ...[
              const SizedBox(height: 8),
              Container(
                height: 320,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.black,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: _logLines.isEmpty
                    ? const Center(
                  child: Text(
                    'No logs yet',
                    style: TextStyle(color: Colors.white70),
                  ),
                )
                    : ListView.builder(
                  reverse: false,
                  itemCount: _logLines.length,
                  itemBuilder: (context, index) {
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 4),
                      child: Text(
                        _logLines[index],
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontFamily: 'monospace',
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}