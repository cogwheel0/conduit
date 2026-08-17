import '../models/chat_message.dart';

/// Serializers for message fields OpenWebUI persists inside chat blobs.
///
/// Every path that writes message objects the server stores wholesale — the
/// API chat push, the sync-outbox echo rows, and the direct/Hermes persisted
/// payloads — must use these shapes: the server and web client read
/// `code_executions` (snake_case) and citation-shaped `sources`, and the
/// server's merge replaces each message object verbatim.

/// Converts ChatSourceReference list back to OpenWebUI's expected format.
/// OpenWebUI expects: { source: {...}, document: [...], metadata: [...] }
/// But ChatSourceReference stores: { id, title, url, snippet, type, metadata }
List<Map<String, dynamic>> convertSourcesToOpenWebUIFormat(
  List<ChatSourceReference> sources,
) {
  return sources.map((ref) {
    final result = <String, dynamic>{};

    // Build the source object
    final sourceObj = <String, dynamic>{};
    if (ref.id != null) sourceObj['id'] = ref.id;
    if (ref.title != null) sourceObj['name'] = ref.title;
    if (ref.url != null) sourceObj['url'] = ref.url;
    if (ref.type != null) sourceObj['type'] = ref.type;

    // Extract nested source from metadata if present
    final metadataSource = ref.metadata?['source'];
    if (metadataSource is Map) {
      for (final entry in metadataSource.entries) {
        sourceObj[entry.key.toString()] ??= entry.value;
      }
    }

    if (sourceObj.isNotEmpty) {
      result['source'] = sourceObj;
    }

    // Extract documents from metadata or use snippet
    final documents = ref.metadata?['documents'];
    if (documents is List && documents.isNotEmpty) {
      result['document'] = documents;
    } else if (ref.snippet != null && ref.snippet!.isNotEmpty) {
      result['document'] = [ref.snippet];
    }

    // Extract metadata items
    final metadataItems = ref.metadata?['items'];
    if (metadataItems is List && metadataItems.isNotEmpty) {
      result['metadata'] = metadataItems;
    } else {
      // Create a basic metadata entry
      final basicMeta = <String, dynamic>{};
      if (ref.id != null) basicMeta['source'] = ref.id;
      if (ref.title != null) basicMeta['name'] = ref.title;
      if (result['document'] is List) {
        result['metadata'] = List.generate(
          (result['document'] as List).length,
          (_) => Map<String, dynamic>.from(basicMeta),
        );
      }
    }

    // Extract distances if present
    final distances = ref.metadata?['distances'];
    if (distances is List && distances.isNotEmpty) {
      result['distances'] = distances;
    }

    return result;
  }).toList();
}

/// Converts ChatCodeExecution list to OpenWebUI's expected format.
/// OpenWebUI expects `code_executions` (snake_case) with specific structure.
/// ChatCodeExecution stores: { id, name, language, code, result, metadata }
/// OpenWebUI expects: { id, name, code, language?, result?: { error?, output?, files? } }
List<Map<String, dynamic>> convertCodeExecutionsToOpenWebUIFormat(
  List<ChatCodeExecution> executions,
) {
  return executions.map((exec) {
    final result = <String, dynamic>{
      'id': exec.id,
      if (exec.name != null) 'name': exec.name,
      if (exec.code != null) 'code': exec.code,
      if (exec.language != null) 'language': exec.language,
    };

    // Convert the result if present
    if (exec.result != null) {
      final execResult = <String, dynamic>{};
      if (exec.result!.output != null) {
        execResult['output'] = exec.result!.output;
      }
      if (exec.result!.error != null) {
        execResult['error'] = exec.result!.error;
      }
      if (exec.result!.files.isNotEmpty) {
        execResult['files'] = exec.result!.files
            .map(
              (f) => <String, dynamic>{
                if (f.name != null) 'name': f.name,
                if (f.url != null) 'url': f.url,
              },
            )
            .toList();
      }
      if (execResult.isNotEmpty) {
        result['result'] = execResult;
      }
    }

    return result;
  }).toList();
}

/// Drops null values and empty entries so the server never stores
/// client-internal nulls inside message `files`.
List<Map<String, dynamic>>? sanitizeFilesForWebUi(
  List<Map<String, dynamic>>? files,
) {
  if (files == null || files.isEmpty) {
    return null;
  }
  final sanitized = <Map<String, dynamic>>[];
  for (final entry in files) {
    final safe = <String, dynamic>{};
    for (final MapEntry(:key, :value) in entry.entries) {
      if (value == null) continue;
      safe[key.toString()] = value;
    }
    if (safe.isNotEmpty) {
      sanitized.add(safe);
    }
  }
  return sanitized.isNotEmpty ? sanitized : null;
}
