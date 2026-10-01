import 'dart:convert';

import 'package:conduit_core/features/direct_connections/models/direct_mcp_content.dart';
import 'package:conduit_core/features/direct_connections/models/direct_mcp_server.dart';
import 'package:conduit_core/features/direct_connections/providers/direct_mcp_providers.dart';
import 'package:conduit_core/features/direct_connections/services/direct_mcp_client.dart';
import 'package:mcp_dart/mcp_dart.dart' as mcp;

/// How a [DirectMcpContentLoadSession] load ended.
sealed class DirectMcpLoadOutcome<T> {
  const DirectMcpLoadOutcome();
}

/// The server answered with [value].
final class DirectMcpLoaded<T> extends DirectMcpLoadOutcome<T> {
  const DirectMcpLoaded(this.value);

  final T value;
}

/// The load failed with [error] (a [DirectProviderException] carries a
/// reason the UI can word).
final class DirectMcpLoadFailed<T> extends DirectMcpLoadOutcome<T> {
  const DirectMcpLoadFailed(this.error);

  final Object error;
}

/// The load was cancelled, replaced by a newer one or aborted; there is
/// nothing to show.
final class DirectMcpLoadSuperseded<T> extends DirectMcpLoadOutcome<T> {
  const DirectMcpLoadSuperseded();
}

/// Runs the Direct MCP content sheet's prompt and resource loads one at a
/// time, latest wins: starting a load, [cancel] and [dispose] abort the one
/// in flight and make its result [DirectMcpLoadSuperseded].
///
/// It owns the abort controller, so the sheet never touches `mcp_dart`.
final class DirectMcpContentLoadSession {
  int _generation = 0;
  mcp.BasicAbortController? _abort;

  /// Loads [prompt]'s messages with [arguments] through [loader].
  Future<DirectMcpLoadOutcome<DirectMcpPromptPreview>> loadPrompt(
    DirectMcpPromptPreviewLoader loader,
    DirectMcpServer server,
    DirectMcpPromptSummary prompt,
    Map<String, String> arguments,
  ) => _run((signal) => loader(server, prompt, arguments, signal));

  /// Reads [resource] through [loader].
  Future<DirectMcpLoadOutcome<DirectMcpResourcePreview>> loadResource(
    DirectMcpResourcePreviewLoader loader,
    DirectMcpServer server,
    DirectMcpResourceSummary resource,
  ) => _run((signal) => loader(server, resource, signal));

  /// Aborts the load in flight, if any.
  void cancel() {
    _generation++;
    _abort?.abort();
    _abort = null;
  }

  /// Same as [cancel]; the session is not used afterwards.
  void dispose() => cancel();

  Future<DirectMcpLoadOutcome<T>> _run<T>(
    Future<T> Function(mcp.AbortSignal signal) operation,
  ) async {
    final generation = ++_generation;
    final abort = mcp.BasicAbortController();
    _abort?.abort();
    _abort = abort;
    try {
      abort.signal.throwIfAborted();
      final value = await operation(abort.signal);
      if (generation != _generation) return DirectMcpLoadSuperseded<T>();
      return DirectMcpLoaded<T>(value);
    } catch (error) {
      if (generation != _generation || error is mcp.AbortError) {
        return DirectMcpLoadSuperseded<T>();
      }
      return DirectMcpLoadFailed<T>(error);
    } finally {
      if (generation == _generation && identical(_abort, abort)) {
        _abort = null;
      }
    }
  }
}

/// The prompts in [prompts] whose name, display name or description contains
/// [query], ignoring case and surrounding space; all of them for an empty
/// query.
List<DirectMcpPromptSummary> filterDirectMcpPrompts(
  Iterable<DirectMcpPromptSummary> prompts,
  String query,
) {
  final needle = query.trim().toLowerCase();
  return [
    for (final prompt in prompts)
      if (_matches(needle, prompt.displayName, prompt.name, prompt.description))
        prompt,
  ];
}

/// The resources in [resources] whose display name, URI or description
/// contains [query]; see [filterDirectMcpPrompts].
List<DirectMcpResourceSummary> filterDirectMcpResources(
  Iterable<DirectMcpResourceSummary> resources,
  String query,
) {
  final needle = query.trim().toLowerCase();
  return [
    for (final resource in resources)
      if (_matches(
        needle,
        resource.displayName,
        resource.uri,
        resource.description,
      ))
        resource,
  ];
}

bool _matches(String needle, String first, String second, String third) =>
    needle.isEmpty ||
    first.toLowerCase().contains(needle) ||
    second.toLowerCase().contains(needle) ||
    third.toLowerCase().contains(needle);

/// Whether [text] is over the size a composer insertion may have.
bool directMcpInsertionTooLarge(String text) =>
    utf8.encode(text).length > kDirectMcpMaxInsertionBytes;

/// Whether [value] is over the size one prompt argument may have.
bool directMcpArgumentValueTooLarge(String value) =>
    utf8.encode(value).length > kDirectMcpMaxPromptArgumentValueBytes;
