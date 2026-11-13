import 'package:conduit_core/features/direct_connections/models/direct_completion.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_content.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_client.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_oauth.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_server_store.dart';
import 'package:conduit_protocol/conduit_protocol.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;
import 'package:riverpod/riverpod.dart';
import 'package:uuid/uuid.dart';

import 'settled.dart';

/// Implements `mcp.*`: MCP servers the app talks to itself.
///
/// As with `direct.*`, what is safe is the core's to decide: which
/// credentials survive an address change, when approvals are forgotten,
/// the OAuth flow and its loopback listener. This translates between the
/// protocol, which never carries a secret back out, and the core's server.
final class McpService {
  McpService(this._container);

  final ProviderContainer _container;

  Future<McpServerList> list() async =>
      McpServerList(servers: (await _servers()).map(_summarize).toList());

  Future<McpServerList> save(McpServerEdit edit) async {
    final previous = await _existing(edit.id);
    final server = _apply(edit, previous);
    try {
      await _container
          .read(directMcpServersProvider.notifier)
          .upsert(
            server,
            expectedPrevious: previous,
            // Only credentials typed again in this edit may follow a new
            // address; the core strips the stored ones otherwise.
            endpointCredentialsConfirmed:
                edit.bearerToken != null || edit.customHeaders != null,
          );
    } on DirectMcpServerConflictException {
      throw const RpcError(
        code: ConduitErrorCodes.conflict,
        debugMessage: 'the server changed elsewhere; reopen it',
      );
    }
    return list();
  }

  Future<McpServerList> remove(String id) async {
    await _container.read(directMcpServersProvider.notifier).remove(id);
    return list();
  }

  Future<McpServerList> setEnabled(String id, bool enabled) async {
    final previous = (await _existing(id))!;
    await _container
        .read(directMcpServersProvider.notifier)
        .upsert(
          previous.copyWith(enabled: enabled),
          expectedPrevious: previous,
        );
    return list();
  }

  /// Connects to the server as edited and counts its tools.
  Future<McpTestResult> test(McpServerEdit edit) async {
    final previous = await _existing(edit.id);
    final DirectMcpServer server;
    try {
      server = _apply(edit.copyWith(enabled: true), previous);
    } on RpcError catch (error) {
      return McpTestResult(reachable: false, message: error.debugMessage);
    }
    final oauth = _container.read(directMcpOAuthCoordinatorProvider);
    try {
      final session = await DirectMcpToolSession.open(
        <DirectMcpServer>[server],
        // A sign-in belongs to the stored server; an unsaved edit has none
        // of its own yet.
        authorizationResolver: (candidate, {forceRefresh = false}) =>
            oauth.accessTokenFor(
              server.authMode == DirectMcpAuthMode.oauth && previous != null
                  ? previous
                  : candidate,
              forceRefresh: forceRefresh,
            ),
      );
      try {
        return McpTestResult(
          reachable: true,
          toolCount: session.definitions.length,
        );
      } finally {
        await session.close();
      }
    } on DirectMcpOAuthException catch (error) {
      return McpTestResult(reachable: false, message: error.message);
    } on Object {
      return const McpTestResult(
        reachable: false,
        message: 'Could not connect to this MCP server.',
      );
    }
  }

  /// Signs in with OAuth and answers once that has finished.
  Future<McpServerList> connect(String id) async {
    final server = (await _existing(id))!;
    try {
      await _container.read(directMcpOAuthCoordinatorProvider).connect(server);
    } on DirectMcpOAuthException catch (error) {
      throw RpcError(
        code: ConduitErrorCodes.connectionFailed,
        args: <String, String>{'detail': error.message},
        debugMessage: error.message,
      );
    }
    await _container.read(directMcpServersProvider.notifier).reload();
    return list();
  }

  Future<void> cancelConnect(String id) =>
      _container.read(directMcpOAuthCoordinatorProvider).cancel(id);

  Future<McpServerList> disconnect(String id) async {
    final server = (await _existing(id))!;
    await _container.read(directMcpOAuthCoordinatorProvider).disconnect(server);
    await _container.read(directMcpServersProvider.notifier).reload();
    return list();
  }

  Future<McpServerList> forgetApproval(McpForgetApproval request) async {
    final server = (await _existing(request.serverId))!;
    final servers = _container.read(directMcpServersProvider.notifier);
    if (request.digest case final digest?) {
      await servers.revokeRememberedApproval(server, digest);
    } else {
      await servers.revokeAllRememberedApprovals(server);
    }
    return list();
  }

  /// What each server offered when the content sheet last asked, so a
  /// prompt or resource is fetched as the summary the user chose -- the
  /// core checks it has not changed since.
  final Map<String, DirectMcpContentInventory> _inventories =
      <String, DirectMcpContentInventory>{};

  Future<McpContent> content(String id) async {
    final server = await _enabled(id);
    final inventory = await _contentCall(
      () => _container.read(directMcpContentInventoryLoaderProvider)(server),
    );
    _inventories[id] = inventory;
    return McpContent(
      serverId: id,
      serverName: inventory.serverName,
      prompts: <McpPromptSummary>[
        for (final prompt in inventory.prompts)
          McpPromptSummary(
            name: prompt.name,
            displayName: prompt.displayName,
            description: prompt.description,
            arguments: <McpPromptArgument>[
              for (final argument in prompt.arguments)
                McpPromptArgument(
                  name: argument.name,
                  label: argument.label,
                  description: argument.description,
                  required: argument.required,
                ),
            ],
          ),
      ],
      resources: <McpResourceSummary>[
        for (final resource in inventory.resources)
          McpResourceSummary(
            uri: resource.uri,
            displayName: resource.displayName,
            description: resource.description,
            mimeType: resource.mimeType,
          ),
      ],
    );
  }

  Future<McpContentPreview> getPrompt(McpGetPrompt request) async {
    final server = await _enabled(request.serverId);
    final prompt = _inventories[request.serverId]?.prompts
        .where((candidate) => candidate.name == request.name)
        .firstOrNull;
    if (prompt == null) throw _changed;
    final preview = await _contentCall(
      () => _container.read(directMcpPromptPreviewLoaderProvider)(
        server,
        prompt,
        request.arguments,
        mcp.BasicAbortController().signal,
      ),
    );
    return McpContentPreview(
      messages: <McpPromptMessage>[
        for (final message in preview.messages)
          McpPromptMessage(role: message.role, text: message.text),
      ],
    );
  }

  Future<McpContentPreview> readResource(McpReadResource request) async {
    final server = await _enabled(request.serverId);
    final resource = _inventories[request.serverId]?.resources
        .where((candidate) => candidate.uri == request.uri)
        .firstOrNull;
    if (resource == null) throw _changed;
    final preview = await _contentCall(
      () => _container.read(directMcpResourcePreviewLoaderProvider)(
        server,
        resource,
        mcp.BasicAbortController().signal,
      ),
    );
    return McpContentPreview(
      messages: <McpPromptMessage>[
        McpPromptMessage(role: '', text: preview.text),
      ],
    );
  }

  static const RpcError _changed = RpcError(
    code: ConduitErrorCodes.invalidParams,
    args: <String, String>{'reason': 'changed'},
    debugMessage: 'that item is no longer offered; refresh the list',
  );

  /// Runs a content request, with the core's failure reasons as the
  /// protocol's.
  static Future<T> _contentCall<T>(Future<T> Function() call) async {
    try {
      return await call();
    } on DirectProviderException catch (error) {
      final reason = switch (error.reason) {
        DirectProviderFailureReason.changed => 'changed',
        DirectProviderFailureReason.unsupported => 'unsupported',
        DirectProviderFailureReason.tooLarge => 'tooLarge',
        null => null,
      };
      throw RpcError(
        code: reason == null
            ? ConduitErrorCodes.connectionFailed
            : ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': ?reason},
        debugMessage: error.message,
      );
    }
  }

  Future<DirectMcpServer> _enabled(String id) async {
    final server = (await _existing(id))!;
    if (!server.enabled) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: 'MCP server $id is turned off',
      );
    }
    return server;
  }

  Future<List<DirectMcpServer>> _servers() =>
      readSettled(_container, directMcpServersProvider.future);

  Future<DirectMcpServer?> _existing(String? id) async {
    if (id == null) return null;
    final found = (await _servers())
        .where((server) => server.id == id)
        .firstOrNull;
    if (found == null) {
      throw RpcError(
        code: ConduitErrorCodes.notFound,
        debugMessage: 'no MCP server $id',
      );
    }
    return found;
  }

  /// [edit] over [previous], or a new server, validated.
  static DirectMcpServer _apply(McpServerEdit edit, DirectMcpServer? previous) {
    final auth = switch (edit.auth) {
      McpAuth.none => DirectMcpAuthMode.none,
      McpAuth.bearer => DirectMcpAuthMode.bearer,
      McpAuth.oauth => DirectMcpAuthMode.oauth,
    };
    final token = switch (edit.bearerToken) {
      null => previous?.bearerToken,
      final given when given.trim().isEmpty => null,
      final given => given.trim(),
    };
    final endpoint = edit.endpoint.trim();
    final server = DirectMcpServer(
      id: previous?.id ?? const Uuid().v4(),
      name: edit.name.trim(),
      endpoint: endpoint,
      enabled: edit.enabled,
      authMode: auth,
      bearerToken: auth == DirectMcpAuthMode.bearer ? token : null,
      // Kept only while it still belongs to this address.
      oauthTokens:
          auth == DirectMcpAuthMode.oauth &&
              previous?.oauthTokens?.appliesToEndpoint(endpoint) == true
          ? previous!.oauthTokens
          : null,
      allowInsecureCredentials: edit.allowInsecureCredentials,
      customHeaders:
          edit.customHeaders ??
          previous?.customHeaders ??
          const <String, String>{},
      rememberedApprovals:
          previous?.rememberedApprovals ??
          const <DirectMcpRememberedApproval>[],
    );
    // Plain HTTP with credentials to another computer is a question for
    // the user, not a validation failure: the window asks and sends again.
    if (server.requiresInsecureCredentialConfirmation &&
        !server.allowInsecureCredentials) {
      throw const RpcError(
        code: ConduitErrorCodes.invalidParams,
        args: <String, String>{'reason': 'insecure'},
        debugMessage: 'confirm sending credentials over plain HTTP',
      );
    }
    final invalid = server.validateOrNull();
    if (invalid != null) {
      throw RpcError(
        code: ConduitErrorCodes.invalidParams,
        debugMessage: invalid,
      );
    }
    return server;
  }

  static McpServerSummary _summarize(DirectMcpServer server) =>
      McpServerSummary(
        id: server.id,
        name: server.name,
        endpoint: server.endpoint,
        enabled: server.enabled,
        auth: switch (server.authMode) {
          DirectMcpAuthMode.none => McpAuth.none,
          DirectMcpAuthMode.bearer => McpAuth.bearer,
          DirectMcpAuthMode.oauth => McpAuth.oauth,
        },
        hasBearerToken: (server.bearerToken ?? '').isNotEmpty,
        customHeaderNames: server.customHeaders.keys.toList(growable: false),
        oauthConnected: server.oauthTokens != null,
        allowInsecureCredentials: server.allowInsecureCredentials,
        approvals: <McpApprovalSummary>[
          for (final approval in server.rememberedApprovals)
            McpApprovalSummary(
              digest: approval.digest,
              toolName: approval.displayName,
              createdAtMs: approval.createdAt.millisecondsSinceEpoch,
            ),
        ],
      );
}
