import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:material_ui/material_ui.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

import '../../../l10n/app_localizations.dart';
import '../../../shared/theme/conduit_input_styles.dart';
import '../../../shared/theme/theme_extensions.dart';
import '../../../shared/widgets/adaptive_dropdown_field.dart';
import '../../../shared/widgets/conduit_components.dart';
import '../../../shared/widgets/themed_sheets.dart';
import '../models/direct_completion.dart';
import '../models/direct_mcp_content.dart';
import '../models/direct_mcp_server.dart';
import '../providers/direct_mcp_providers.dart';
import '../services/direct_mcp_client.dart';

class DirectMcpContentSheet extends ConsumerStatefulWidget {
  const DirectMcpContentSheet({super.key});

  static Future<String?> show(BuildContext context) =>
      ThemedSheets.showRoundedPage<String>(
        context: context,
        builder: (_) => const DirectMcpContentSheet(),
      );

  @override
  ConsumerState<DirectMcpContentSheet> createState() =>
      _DirectMcpContentSheetState();
}

class _DirectMcpContentSheetState extends ConsumerState<DirectMcpContentSheet> {
  final _searchController = TextEditingController();
  String? _serverId;
  String? _preview;
  String? _error;
  DirectMcpServer? _argumentServer;
  DirectMcpPromptSummary? _argumentPrompt;
  bool _loading = false;
  int _requestGeneration = 0;
  mcp.BasicAbortController? _abort;

  @override
  void dispose() {
    _requestGeneration++;
    _abort?.abort();
    _searchController.dispose();
    super.dispose();
  }

  void _selectPrompt(DirectMcpServer server, DirectMcpPromptSummary prompt) {
    if (prompt.arguments.isEmpty) {
      unawaited(_loadPrompt(server, prompt, const {}));
      return;
    }
    _cancelLoad();
    setState(() {
      _argumentServer = server;
      _argumentPrompt = prompt;
      _error = null;
    });
  }

  Future<void> _loadPrompt(
    DirectMcpServer server,
    DirectMcpPromptSummary prompt,
    Map<String, String> arguments,
  ) async {
    final l10n = AppLocalizations.of(context)!;
    await _load((signal) async {
      final result = await ref.read(directMcpPromptPreviewLoaderProvider)(
        server,
        prompt,
        arguments,
        signal,
      );
      return formatDirectMcpPromptInsertion(
        heading: l10n.directMcpContentPromptHeading(
          server.name,
          prompt.displayName,
        ),
        preview: result,
        roleLabel: (role) => switch (role) {
          'system' => l10n.system,
          'assistant' => l10n.directMcpContentRoleAssistant,
          _ => l10n.directMcpContentRoleUser,
        },
      );
    });
  }

  Future<void> _loadResource(
    DirectMcpServer server,
    DirectMcpResourceSummary resource,
  ) {
    final l10n = AppLocalizations.of(context)!;
    return _load((signal) async {
      final result = await ref.read(directMcpResourcePreviewLoaderProvider)(
        server,
        resource,
        signal,
      );
      return formatDirectMcpResourceInsertion(
        heading: l10n.directMcpContentResourceHeading(
          server.name,
          resource.uri,
        ),
        preview: result,
      );
    });
  }

  Future<void> _load(
    Future<String> Function(mcp.AbortSignal signal) operation,
  ) async {
    final generation = ++_requestGeneration;
    final abort = mcp.BasicAbortController();
    _abort?.abort();
    _abort = abort;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      abort.signal.throwIfAborted();
      final preview = await operation(abort.signal);
      if (!mounted || generation != _requestGeneration) return;
      if (utf8.encode(preview).length > kDirectMcpMaxInsertionBytes) {
        setState(
          () => _error = AppLocalizations.of(context)!.directMcpContentTooLarge,
        );
        return;
      }
      setState(() => _preview = preview);
    } catch (error) {
      if (!mounted ||
          generation != _requestGeneration ||
          error is mcp.AbortError) {
        return;
      }
      setState(() => _error = _messageFor(error));
    } finally {
      if (mounted && generation == _requestGeneration) {
        setState(() => _loading = false);
      }
    }
  }

  void _cancelLoad() {
    _requestGeneration++;
    _abort?.abort();
    setState(() {
      _loading = false;
      _error = null;
    });
  }

  String _messageFor(Object error) {
    final l10n = AppLocalizations.of(context)!;
    final reason = error is DirectProviderException ? error.reason : null;
    return switch (reason) {
      DirectProviderFailureReason.changed => l10n.directMcpContentChanged,
      DirectProviderFailureReason.unsupported =>
        l10n.directMcpContentUnsupported,
      DirectProviderFailureReason.tooLarge => l10n.directMcpContentTooLarge,
      null => l10n.directMcpContentRequestFailed,
    };
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    final serversAsync = ref.watch(directMcpServersProvider);
    return Material(
      color: theme.surfaceBackground,
      child: SafeArea(
        child: serversAsync.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (_, _) => _buildMessage(l10n.directMcpContentLoadFailed),
          data: (allServers) {
            final servers = allServers
                .where((server) => server.enabled)
                .toList();
            if (servers.isEmpty) {
              return _buildMessage(l10n.directMcpContentEmpty);
            }
            final selected = servers.firstWhere(
              (server) => server.id == _serverId,
              orElse: () => servers.first,
            );
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                _buildHeader(selected),
                if (_error != null && !_loading) _buildError(_error!),
                if (_preview != null)
                  Expanded(child: _buildPreview())
                else if (_argumentPrompt != null)
                  Expanded(child: _buildArguments())
                else if (_loading)
                  Expanded(child: _buildLoading())
                else ...[
                  if (servers.length > 1)
                    Padding(
                      padding: const EdgeInsets.fromLTRB(
                        Spacing.lg,
                        Spacing.md,
                        Spacing.lg,
                        0,
                      ),
                      child: AdaptiveDropdownField<String>(
                        value: selected.id,
                        nativeTitle: l10n.directMcpContentServer,
                        cancelLabel: l10n.cancel,
                        decoration: context.conduitInputStyles
                            .standard()
                            .copyWith(labelText: l10n.directMcpContentServer),
                        options: [
                          for (final server in servers)
                            AdaptiveDropdownOption(
                              value: server.id,
                              label: server.name,
                            ),
                        ],
                        onChanged: (serverId) => setState(() {
                          _serverId = serverId;
                          _error = null;
                        }),
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(
                      Spacing.lg,
                      Spacing.md,
                      Spacing.lg,
                      Spacing.sm,
                    ),
                    child: Semantics(
                      textField: true,
                      label: l10n.directMcpContentSearch,
                      child: TextField(
                        key: const Key('direct-mcp-content-search'),
                        controller: _searchController,
                        onChanged: (_) => setState(() {}),
                        decoration: context.conduitInputStyles
                            .standard(hint: l10n.directMcpContentSearch)
                            .copyWith(prefixIcon: const Icon(Icons.search)),
                      ),
                    ),
                  ),
                  Expanded(child: _buildInventory(selected)),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _buildHeader(DirectMcpServer selected) {
    final l10n = AppLocalizations.of(context)!;
    final theme = context.conduitTheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        Spacing.lg,
        Spacing.sm,
        Spacing.sm,
        Spacing.sm,
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(l10n.directMcpContentTitle, style: theme.headingSmall),
          ),
          if (_preview == null && !_loading)
            IconButton(
              key: const Key('direct-mcp-content-refresh'),
              tooltip: l10n.directMcpContentRefresh,
              onPressed: () {
                ref.invalidate(directMcpContentInventoryProvider(selected.id));
                setState(() => _error = null);
              },
              icon: const Icon(Icons.refresh),
            ),
          IconButton(
            tooltip: l10n.close,
            onPressed: () => Navigator.of(context).pop(),
            icon: const Icon(Icons.close),
          ),
        ],
      ),
    );
  }

  Widget _buildInventory(DirectMcpServer server) {
    final l10n = AppLocalizations.of(context)!;
    final inventory = ref.watch(directMcpContentInventoryProvider(server.id));
    return inventory.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => _buildMessage(
        l10n.directMcpContentLoadFailed,
        action: ConduitButton(
          text: l10n.retry,
          onPressed: () =>
              ref.invalidate(directMcpContentInventoryProvider(server.id)),
        ),
      ),
      data: (content) {
        final query = _searchController.text.trim().toLowerCase();
        final prompts = content.prompts.where(
          (prompt) => _matches(
            query,
            prompt.displayName,
            prompt.name,
            prompt.description,
          ),
        );
        final resources = content.resources.where(
          (resource) => _matches(
            query,
            resource.displayName,
            resource.uri,
            resource.description,
          ),
        );
        if (prompts.isEmpty && resources.isEmpty) {
          return _buildMessage(
            query.isEmpty
                ? l10n.directMcpContentEmpty
                : l10n.directMcpContentNoMatches,
          );
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(
            Spacing.lg,
            Spacing.sm,
            Spacing.lg,
            Spacing.lg,
          ),
          children: [
            if (prompts.isNotEmpty) ...[
              _sectionLabel(l10n.directMcpContentPrompts),
              for (final prompt in prompts)
                ListTile(
                  key: ValueKey('direct-mcp-prompt-${prompt.name}'),
                  title: Text(prompt.displayName),
                  subtitle: prompt.description.isEmpty
                      ? null
                      : Text(prompt.description),
                  leading: const Icon(Icons.chat_bubble_outline),
                  onTap: () => _selectPrompt(server, prompt),
                ),
            ],
            if (resources.isNotEmpty) ...[
              const SizedBox(height: Spacing.md),
              _sectionLabel(l10n.directMcpContentResources),
              for (final resource in resources)
                ListTile(
                  key: ValueKey('direct-mcp-resource-${resource.uri}'),
                  title: Text(resource.displayName),
                  subtitle: Text(
                    resource.description.isEmpty
                        ? resource.uri
                        : '${resource.description}\n${resource.uri}',
                  ),
                  leading: const Icon(Icons.description_outlined),
                  onTap: () => _loadResource(server, resource),
                ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildLoading() {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      liveRegion: true,
      label: l10n.directMcpContentLoading,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const CircularProgressIndicator(),
            const SizedBox(height: Spacing.md),
            Text(l10n.directMcpContentLoading),
            const SizedBox(height: Spacing.md),
            ConduitButton(
              key: const Key('direct-mcp-content-cancel'),
              text: l10n.cancel,
              isSecondary: true,
              onPressed: _cancelLoad,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildArguments() {
    final server = _argumentServer!;
    final prompt = _argumentPrompt!;
    return _DirectMcpPromptArgumentsForm(
      prompt: prompt,
      onCancel: () => setState(() {
        _argumentServer = null;
        _argumentPrompt = null;
      }),
      onSubmit: (arguments) {
        setState(() {
          _argumentServer = null;
          _argumentPrompt = null;
        });
        unawaited(_loadPrompt(server, prompt, arguments));
      },
    );
  }

  Widget _buildPreview() {
    final l10n = AppLocalizations.of(context)!;
    final preview = _preview!;
    return Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.directMcpContentPreviewTitle,
            style: context.conduitTheme.headingSmall,
          ),
          const SizedBox(height: Spacing.sm),
          Expanded(
            child: DecoratedBox(
              decoration: BoxDecoration(
                border: Border.all(color: context.conduitTheme.dividerColor),
                borderRadius: BorderRadius.circular(AppBorderRadius.medium),
              ),
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(Spacing.md),
                child: SelectableText(preview),
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Semantics(
            liveRegion: true,
            label: l10n.charCount(preview.length),
            child: Text(
              l10n.charCount(preview.length),
              textAlign: TextAlign.end,
              style: context.conduitTheme.bodySmall?.copyWith(
                color: context.conduitTheme.textSecondary,
              ),
            ),
          ),
          const SizedBox(height: Spacing.sm),
          Row(
            children: [
              Expanded(
                child: ConduitButton(
                  text: l10n.back,
                  isSecondary: true,
                  onPressed: () => setState(() {
                    _preview = null;
                    _error = null;
                  }),
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: ConduitButton(
                  key: const Key('direct-mcp-content-insert'),
                  text: l10n.directMcpContentInsert,
                  onPressed: () => Navigator.of(context).pop(preview),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildMessage(String message, {Widget? action}) => Center(
    child: Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(message, textAlign: TextAlign.center),
          if (action != null) ...[const SizedBox(height: Spacing.md), action],
        ],
      ),
    ),
  );

  Widget _buildError(String message) => Semantics(
    liveRegion: true,
    child: Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: Spacing.lg,
        vertical: Spacing.sm,
      ),
      child: Text(
        message,
        textAlign: TextAlign.center,
        style: TextStyle(color: context.conduitTheme.error),
      ),
    ),
  );

  Widget _sectionLabel(String label) => Semantics(
    header: true,
    child: Text(label, style: context.conduitTheme.label),
  );

  bool _matches(String query, String first, String second, String third) =>
      query.isEmpty ||
      first.toLowerCase().contains(query) ||
      second.toLowerCase().contains(query) ||
      third.toLowerCase().contains(query);
}

class _DirectMcpPromptArgumentsForm extends StatefulWidget {
  const _DirectMcpPromptArgumentsForm({
    required this.prompt,
    required this.onCancel,
    required this.onSubmit,
  });

  final DirectMcpPromptSummary prompt;
  final VoidCallback onCancel;
  final ValueChanged<Map<String, String>> onSubmit;

  @override
  State<_DirectMcpPromptArgumentsForm> createState() =>
      _DirectMcpPromptArgumentsFormState();
}

class _DirectMcpPromptArgumentsFormState
    extends State<_DirectMcpPromptArgumentsForm> {
  final _formKey = GlobalKey<FormState>();
  late final Map<String, TextEditingController> _controllers = {
    for (final argument in widget.prompt.arguments)
      argument.name: TextEditingController(),
  };

  @override
  void dispose() {
    for (final controller in _controllers.values) {
      controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.all(Spacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            widget.prompt.displayName,
            style: context.conduitTheme.headingSmall,
          ),
          const SizedBox(height: Spacing.md),
          Expanded(
            child: Form(
              key: _formKey,
              child: SingleChildScrollView(
                child: Column(
                  children: [
                    for (final argument in widget.prompt.arguments)
                      Padding(
                        padding: const EdgeInsets.only(bottom: Spacing.md),
                        child: TextFormField(
                          key: ValueKey('direct-mcp-argument-${argument.name}'),
                          controller: _controllers[argument.name],
                          decoration: context.conduitInputStyles
                              .standard(
                                hint: argument.description.isEmpty
                                    ? null
                                    : argument.description,
                              )
                              .copyWith(
                                labelText: argument.required
                                    ? '${argument.label} *'
                                    : argument.label,
                              ),
                          validator: (value) {
                            if (argument.required &&
                                (value == null || value.trim().isEmpty)) {
                              return l10n.requiredFieldHelper;
                            }
                            if (utf8.encode(value ?? '').length >
                                kDirectMcpMaxPromptArgumentValueBytes) {
                              return l10n.directMcpContentTooLarge;
                            }
                            return null;
                          },
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ),
          Row(
            children: [
              Expanded(
                child: ConduitButton(
                  text: l10n.cancel,
                  isSecondary: true,
                  onPressed: widget.onCancel,
                ),
              ),
              const SizedBox(width: Spacing.sm),
              Expanded(
                child: ConduitButton(
                  text: l10n.continueAction,
                  onPressed: () {
                    if (!_formKey.currentState!.validate()) return;
                    widget.onSubmit({
                      for (final entry in _controllers.entries)
                        if (entry.value.text.isNotEmpty)
                          entry.key: entry.value.text,
                    });
                  },
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
