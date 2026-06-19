/// Shared loader for the golden chat-blob fixtures in
/// test/fixtures/chat_blobs/ (CDT-RFC-001 §12.1).
library;

import 'dart:convert';
import 'dart:io';

import 'package:collection/collection.dart';
import 'package:conduit/core/database/mappers/chat_blob_mapper.dart';

class ChatBlobFixture {
  ChatBlobFixture({
    required this.name,
    required this.description,
    required this.envelope,
    required this.blob,
  });

  final String name;
  final String description;
  final Map<String, dynamic> envelope;
  final Map<String, dynamic> blob;

  String get chatId => envelope['id'] as String;
}

Map<String, dynamic> deepCopyJson(Map<String, dynamic> value) =>
    jsonDecode(jsonEncode(value)) as Map<String, dynamic>;

/// Loads every fixture file. `flutter test` runs with the package root as the
/// working directory.
List<ChatBlobFixture> loadChatBlobFixtures() {
  final dir = Directory('test/fixtures/chat_blobs');
  final files = dir
      .listSync()
      .whereType<File>()
      .where((f) => f.path.endsWith('.json'))
      .sortedBy((f) => f.path);
  if (files.isEmpty) {
    throw StateError('No fixtures found in ${dir.absolute.path}');
  }
  return files.map((file) {
    final raw = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    return ChatBlobFixture(
      name: file.uri.pathSegments.last.replaceAll('.json', ''),
      description: raw['description'] as String,
      envelope: raw['envelope'] as Map<String, dynamic>,
      blob: raw['chat'] as Map<String, dynamic>,
    );
  }).toList();
}

/// Decomposes [fixture] exactly the way the pull sync will: envelope fields
/// from the API envelope, blob handed over as a deep copy so accidental
/// mutation cannot make round-trip comparisons pass vacuously.
ChatRows rowsFromFixture(ChatBlobFixture fixture) {
  return ChatBlobMapper.blobToRows(
    chatId: fixture.chatId,
    blob: deepCopyJson(fixture.blob),
    title: fixture.envelope['title'] as String,
    folderId: fixture.envelope['folder_id'] as String?,
    pinned: (fixture.envelope['pinned'] as bool?) ?? false,
    archived: (fixture.envelope['archived'] as bool?) ?? false,
    createdAt: fixture.envelope['created_at'] as int,
    updatedAt: fixture.envelope['updated_at'] as int,
  );
}
