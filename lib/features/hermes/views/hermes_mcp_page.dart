import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';

import '../../../core/utils/debug_logger.dart';
import '../models/hermes_mcp.dart';
import '../providers/hermes_providers.dart';
import '../services/hermes_desktop_api_service.dart';

final class HermesMcpPage extends ConsumerStatefulWidget {
  const HermesMcpPage({super.key});

  @override
  ConsumerState<HermesMcpPage> createState() => _HermesMcpPageState();
}

final class _HermesMcpPageState extends ConsumerState<HermesMcpPage> {
  late Future<List<HermesMcpServer>> _servers = _load();
  final Map<String, HermesMcpTestResult> _testResults = {};
  final Set<String> _oauthPending = {};

  HermesDesktopApiService get _service {
    final service = ref.read(hermesApiServiceProvider);
    if (service is! HermesDesktopApiService) {
      throw StateError('Desktop Gateway is not connected.');
    }
    return service;
  }

  Future<List<HermesMcpServer>> _load() async {
    try {
      return await _service.mcpServers();
    } catch (error) {
      DebugLogger.warning(
        'mcp-load-failed',
        scope: 'hermes/mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      rethrow;
    }
  }

  void _refresh() {
    if (mounted) setState(() => _servers = _load());
  }

  Future<void> _run(Future<void> Function() action) async {
    try {
      await action();
    } catch (error) {
      DebugLogger.warning(
        'mcp-action-failed',
        scope: 'hermes/mcp',
        data: {'errorType': error.runtimeType.toString()},
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Hermes MCP action failed.')),
      );
    }
  }

  Future<void> _add() async {
    final name = TextEditingController();
    final url = TextEditingController();
    final command = TextEditingController();
    final args = TextEditingController();
    final secret = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add MCP server'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              TextField(
                controller: url,
                decoration: const InputDecoration(labelText: 'HTTP URL'),
              ),
              TextField(
                controller: command,
                decoration: const InputDecoration(labelText: 'stdio command'),
              ),
              TextField(
                controller: args,
                decoration: const InputDecoration(
                  labelText: 'Arguments (one per line)',
                ),
              ),
              TextField(
                controller: secret,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(
                  labelText: 'API key (optional)',
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Add'),
          ),
        ],
      ),
    );
    try {
      if (accepted != true || name.text.trim().isEmpty) return;
      await _service.addMcpServer(
        name: name.text.trim(),
        url: url.text.trim(),
        command: command.text.trim(),
        arguments: args.text
            .split('\n')
            .map((value) => value.trim())
            .where((value) => value.isNotEmpty)
            .toList(),
        bearerToken: secret.text,
      );
      _refresh();
    } finally {
      // Controllers—and therefore the only local copy of the MCP secret—are
      // discarded immediately after the RPC settles.
      name.dispose();
      url.dispose();
      command.dispose();
      args.dispose();
      secret.dispose();
    }
  }

  Future<void> _test(String name) async {
    final result = await _service.testMcpServer(name);
    if (!mounted) return;
    setState(() => _testResults[name] = result);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          result.ok
              ? 'Connected · ${result.tools} tools · ${result.resources} resources · ${result.prompts} prompts'
              : result.error ?? 'MCP test failed',
        ),
      ),
    );
  }

  Future<void> _addPreset() async {
    final entries = await _service.mcpCatalog();
    if (!mounted) return;
    final selected = await showDialog<HermesMcpCatalogEntry>(
      context: context,
      builder: (context) => SimpleDialog(
        title: const Text('Add catalog server'),
        children: [
          for (final entry in entries)
            SimpleDialogOption(
              onPressed: () => Navigator.pop(context, entry),
              child: ListTile(
                title: Text(entry.name),
                subtitle: Text(entry.description),
              ),
            ),
        ],
      ),
    );
    if (selected == null) return;
    final name = selected.name;
    if (name.isEmpty) return;
    await _service.addMcpPreset(name);
    _refresh();
  }

  Future<void> _setApiKey(String name) async {
    final value = TextEditingController();
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Set API key for $name'),
        content: TextField(
          controller: value,
          obscureText: true,
          enableSuggestions: false,
          autocorrect: false,
          decoration: const InputDecoration(labelText: 'API key'),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    try {
      if (accepted != true || value.text.isEmpty) return;
      await _service.setMcpApiKey(name, value.text);
      _refresh();
    } finally {
      value.dispose();
    }
  }

  Future<void> _setEnabled(HermesMcpServer server, bool enabled) async {
    final name = server.name;
    if (name.isEmpty) return;
    await _service.setMcpServerEnabled(name, enabled);
    _refresh();
  }

  Future<void> _oauth(String name) async {
    if (mounted) setState(() => _oauthPending.add(name));
    try {
      if (!await _service.authenticateMcpServer(name)) {
        throw StateError('MCP authentication failed.');
      }
      _refresh();
    } finally {
      if (mounted) setState(() => _oauthPending.remove(name));
    }
  }

  Future<void> _remove(String name) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text('This removes the server from Hermes.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _service.removeMcpServer(name);
    _refresh();
  }

  String _serverSubtitle(HermesMcpServer server) {
    final result = _testResults[server.name];
    final tools = result?.toolNames ?? server.tools;
    return [
      server.enabled ? 'Enabled' : 'Disabled',
      if (server.auth?.isNotEmpty == true) server.auth!,
      if (server.description.isNotEmpty) server.description,
      if (tools.isNotEmpty) 'Tools: ${tools.join(', ')}',
      if (result != null)
        '${result.resources} resources · ${result.prompts} prompts',
    ].join('\n');
  }

  @override
  Widget build(BuildContext context) {
    final connectedService = ref.watch(hermesApiServiceProvider);
    final supportsCredentialUpdate =
        connectedService is HermesDesktopApiService &&
        connectedService.supportsMcpCredentialUpdate;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Hermes MCP'),
        actions: [
          IconButton(
            tooltip: 'Add from catalog',
            onPressed: () => unawaited(_run(_addPreset)),
            icon: const Icon(Icons.auto_awesome_outlined),
          ),
        ],
      ),
      body: FutureBuilder<List<HermesMcpServer>>(
        future: _servers,
        builder: (context, snapshot) {
          if (!snapshot.hasData) {
            if (snapshot.hasError) {
              return const Center(child: Text('Could not load MCP servers.'));
            }
            return const Center(child: CircularProgressIndicator.adaptive());
          }
          final servers = snapshot.data!;
          if (servers.isEmpty) {
            return const Center(child: Text('No MCP servers configured.'));
          }
          return ListView(
            children: [
              for (final server in servers)
                ListTile(
                  title: Text(server.name),
                  subtitle: Text(
                    _serverSubtitle(server),
                    maxLines: 5,
                    overflow: TextOverflow.ellipsis,
                  ),
                  isThreeLine: true,
                  trailing: _oauthPending.contains(server.name)
                      ? const CircularProgressIndicator.adaptive()
                      : PopupMenuButton<String>(
                          onSelected: (action) {
                            final name = server.name;
                            if (action == 'test') {
                              unawaited(_run(() => _test(name)));
                            }
                            if (action == 'oauth') {
                              unawaited(_run(() => _oauth(name)));
                            }
                            if (action == 'key') {
                              unawaited(_run(() => _setApiKey(name)));
                            }
                            if (action == 'enable') {
                              unawaited(_run(() => _setEnabled(server, true)));
                            }
                            if (action == 'disable') {
                              unawaited(_run(() => _setEnabled(server, false)));
                            }
                            if (action == 'remove') {
                              unawaited(_run(() => _remove(name)));
                            }
                          },
                          itemBuilder: (_) => [
                            const PopupMenuItem(
                              value: 'test',
                              child: Text('Test'),
                            ),
                            const PopupMenuItem(
                              value: 'oauth',
                              child: Text('Authenticate'),
                            ),
                            if (supportsCredentialUpdate)
                              const PopupMenuItem(
                                value: 'key',
                                child: Text('Set API key'),
                              ),
                            const PopupMenuItem(
                              value: 'enable',
                              child: Text('Enable tools'),
                            ),
                            const PopupMenuItem(
                              value: 'disable',
                              child: Text('Disable tools'),
                            ),
                            const PopupMenuItem(
                              value: 'remove',
                              child: Text('Remove'),
                            ),
                          ],
                        ),
                ),
            ],
          );
        },
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () => unawaited(_run(_add)),
        child: const Icon(Icons.add),
      ),
    );
  }
}
