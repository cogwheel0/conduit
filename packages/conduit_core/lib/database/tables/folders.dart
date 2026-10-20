import 'package:drift/drift.dart';

/// Folder rows (CDT-RFC-001 §6).
@DataClassName('FolderRow')
class Folders extends Table {
  TextColumn get id => text()();
  TextColumn get name => text()();
  TextColumn get parentId => text().nullable()();

  /// Epoch seconds, server clock.
  IntColumn get createdAt => integer()();
  IntColumn get updatedAt => integer()();
  IntColumn get serverUpdatedAt => integer().nullable()();
  BoolColumn get dirty => boolean().withDefault(const Constant(false))();
  BoolColumn get deleted => boolean().withDefault(const Constant(false))();

  /// meta, is_expanded, data, items, unknown keys — verbatim.
  TextColumn get rawExtra => text().withDefault(const Constant('{}'))();

  @override
  Set<Column> get primaryKey => {id};
}
