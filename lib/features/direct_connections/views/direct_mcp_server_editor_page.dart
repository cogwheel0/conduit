import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:uuid/uuid.dart';

import '../../../l10n/app_localizations.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_dialogs.dart';
import '../../../shared/widgets/utility_components.dart';
import '../models/direct_mcp_server.dart';
import '../providers/direct_mcp_providers.dart';

class DirectMcpServerEditorPage extends ConsumerStatefulWidget {
  const DirectMcpServerEditorPage({super.key, required this.serverId});

  final String serverId;

  @override
  ConsumerState<DirectMcpServerEditorPage> createState() =>
      _DirectMcpServerEditorPageState();
}

class _DirectMcpServerEditorPageState
    extends ConsumerState<DirectMcpServerEditorPage> {
  final _name = TextEditingController();
  final _endpoint = TextEditingController();
  final _token = TextEditingController();
  final _headers = TextEditingController();
  DirectMcpServer? _previous;
  bool _enabled = true;
  bool _initialized = false;
  bool _busy = false;
  String? _message;

  bool get _isNew => widget.serverId == 'new';

  @override
  void dispose() {
    _name.dispose();
    _endpoint.dispose();
    _token.dispose();
    _headers.dispose();
    super.dispose();
  }

  void _initialize(List<DirectMcpServer> servers) {
    if (_initialized) return;
    _initialized = true;
    if (_isNew) return;
    _previous = servers
        .where((server) => server.id == widget.serverId)
        .firstOrNull;
    final server = _previous;
    if (server == null) return;
    _name.text = server.name;
    _endpoint.text = server.endpoint;
    _token.text = server.bearerToken ?? '';
    _headers.text = server.customHeaders.entries
        .map((entry) => '${entry.key}: ${entry.value}')
        .join('\n');
    _enabled = server.enabled;
  }

  DirectMcpServer _draft({bool forceEnabled = false}) {
    final id = _isNew ? const Uuid().v4() : widget.serverId;
    final customHeaders = <String, String>{};
    final normalizedHeaderNames = <String>{};
    for (final rawLine in _headers.text.split('\n')) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;
      final separator = line.indexOf(':');
      if (separator <= 0) {
        throw const FormatException('Enter custom headers as Name: Value.');
      }
      final name = line.substring(0, separator).trim();
      if (!normalizedHeaderNames.add(name.toLowerCase())) {
        throw const FormatException('Custom header names must be unique.');
      }
      customHeaders[name] = line.substring(separator + 1).trim();
    }
    final server = DirectMcpServer(
      id: id,
      name: _name.text.trim(),
      endpoint: _endpoint.text.trim(),
      enabled: forceEnabled || _enabled,
      bearerToken: _token.text.isEmpty ? null : _token.text,
      customHeaders: customHeaders,
    );
    server.validate();
    return server;
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    DirectMcpServer draft;
    try {
      draft = _draft();
    } on FormatException catch (error) {
      setState(() => _message = error.message);
      return;
    }

    var confirmed = false;
    final previous = _previous;
    if (previous != null && previous.origin != draft.origin) {
      confirmed = await ThemedDialogs.confirm(
        context,
        title: l10n.directMcpCredentialTransferTitle,
        message: l10n.directMcpCredentialTransferMessage,
        confirmText: l10n.directMcpCredentialTransferConfirm,
        barrierDismissible: false,
      );
      if (!confirmed) draft = draft.withoutSecrets();
    }
    if (!mounted) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await ref
          .read(directMcpServersProvider.notifier)
          .upsert(
            draft,
            expectedPrevious: previous,
            secretsConfirmedForNewOrigin: confirmed,
          );
      if (mounted) context.pop(true);
    } catch (_) {
      if (mounted) setState(() => _message = l10n.directMcpSaveFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _testConnection() async {
    final l10n = AppLocalizations.of(context)!;
    DirectMcpServer draft;
    try {
      draft = _draft(forceEnabled: true);
    } on FormatException catch (error) {
      setState(() => _message = error.message);
      return;
    }
    setState(() {
      _busy = true;
      _message = l10n.directMcpTesting;
    });
    try {
      final session = await ref.read(directMcpSessionBuilderProvider)([draft]);
      try {
        if (mounted) {
          setState(
            () => _message = l10n.directMcpTestSucceeded(
              session.definitions.length,
            ),
          );
        }
      } finally {
        await session.close();
      }
    } catch (_) {
      if (mounted) setState(() => _message = l10n.directMcpTestFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final previous = _previous;
    if (previous == null) return;
    final confirmed = await ThemedDialogs.confirm(
      context,
      title: l10n.directMcpDeleteTitle,
      message: l10n.directMcpDeleteMessage(previous.name),
      confirmText: l10n.delete,
      isDestructive: true,
    );
    if (!confirmed || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(directMcpServersProvider.notifier).remove(previous.id);
      if (mounted) context.pop(true);
    } catch (_) {
      if (mounted) setState(() => _message = l10n.directMcpDeleteFailed);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final servers = ref.watch(directMcpServersProvider);
    return servers.when(
      loading: () => UtilityPageScaffold.settings(
        title: l10n.directMcpEditorTitle,
        children: const [Center(child: CircularProgressIndicator.adaptive())],
      ),
      error: (_, _) => UtilityPageScaffold.settings(
        title: l10n.directMcpEditorTitle,
        children: [Text(l10n.directMcpLoadFailed)],
      ),
      data: (items) {
        _initialize(items);
        if (!_isNew && _previous == null) {
          return UtilityPageScaffold.settings(
            title: l10n.directMcpEditorTitle,
            children: [Text(l10n.directMcpMissing)],
          );
        }
        return UtilityPageScaffold.settings(
          title: _isNew ? l10n.directMcpAddTitle : l10n.directMcpEditorTitle,
          children: [
            Text(l10n.directMcpReachabilityHelp),
            const SizedBox(height: 16),
            TextField(
              key: const ValueKey('direct-mcp-name'),
              controller: _name,
              enabled: !_busy,
              decoration: InputDecoration(labelText: l10n.directMcpName),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('direct-mcp-endpoint'),
              controller: _endpoint,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              autocorrect: false,
              decoration: InputDecoration(labelText: l10n.directMcpEndpoint),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('direct-mcp-token'),
              controller: _token,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              decoration: InputDecoration(labelText: l10n.directMcpBearerToken),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const ValueKey('direct-mcp-headers'),
              controller: _headers,
              enabled: !_busy,
              minLines: 2,
              maxLines: 5,
              autocorrect: false,
              decoration: InputDecoration(
                labelText: l10n.directMcpCustomHeaders,
                hintText: l10n.directMcpCustomHeadersHint,
              ),
            ),
            SwitchListTile.adaptive(
              key: const ValueKey('direct-mcp-enabled'),
              contentPadding: EdgeInsets.zero,
              title: Text(l10n.enabledLabel),
              value: _enabled,
              onChanged: _busy
                  ? null
                  : (value) => setState(() => _enabled = value),
            ),
            if (_message != null) ...[
              const SizedBox(height: 8),
              Semantics(liveRegion: true, child: Text(_message!)),
            ],
            const SizedBox(height: 16),
            ConduitButton(
              key: const ValueKey('direct-mcp-test'),
              text: l10n.directMcpTestConnection,
              isSecondary: true,
              isLoading: _busy,
              onPressed: _busy ? null : _testConnection,
            ),
            const SizedBox(height: 8),
            ConduitButton(
              key: const ValueKey('direct-mcp-save'),
              text: l10n.save,
              isLoading: _busy,
              onPressed: _busy ? null : _save,
            ),
            if (!_isNew) ...[
              const SizedBox(height: 8),
              ConduitButton(
                key: const ValueKey('direct-mcp-delete'),
                text: l10n.delete,
                isDestructive: true,
                onPressed: _busy ? null : _delete,
              ),
            ],
          ],
        );
      },
    );
  }
}
