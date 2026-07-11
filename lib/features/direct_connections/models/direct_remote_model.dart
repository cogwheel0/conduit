import 'dart:collection';

final class DirectRemoteModel {
  DirectRemoteModel({
    required this.id,
    String? name,
    this.description,
    this.isMultimodal = false,
    Map<String, dynamic> capabilities = const {},
  }) : name = (name == null || name.trim().isEmpty) ? id : name,
       capabilities = UnmodifiableMapView(Map.of(capabilities)) {
    if (id.trim().isEmpty) throw ArgumentError.value(id, 'id');
  }

  final String id;
  final String name;
  final String? description;
  final bool isMultimodal;
  final Map<String, dynamic> capabilities;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is DirectRemoteModel &&
          other.id == id &&
          other.name == name &&
          other.description == description &&
          other.isMultimodal == isMultimodal &&
          _deepEquals(other.capabilities, capabilities);

  @override
  int get hashCode =>
      Object.hash(id, name, description, isMultimodal, _deepHash(capabilities));
}

bool _deepEquals(Object? left, Object? right) {
  if (identical(left, right)) return true;
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final entry in left.entries) {
      if (!right.containsKey(entry.key) ||
          !_deepEquals(entry.value, right[entry.key])) {
        return false;
      }
    }
    return true;
  }
  if (left is Iterable && right is Iterable) {
    final leftIterator = left.iterator;
    final rightIterator = right.iterator;
    while (true) {
      final hasLeft = leftIterator.moveNext();
      final hasRight = rightIterator.moveNext();
      if (hasLeft != hasRight) return false;
      if (!hasLeft) return true;
      if (!_deepEquals(leftIterator.current, rightIterator.current)) {
        return false;
      }
    }
  }
  return left == right;
}

int _deepHash(Object? value) {
  if (value is Map) {
    return Object.hashAllUnordered(
      value.entries.map(
        (entry) => Object.hash(_deepHash(entry.key), _deepHash(entry.value)),
      ),
    );
  }
  if (value is Iterable) {
    return Object.hashAll(value.map(_deepHash));
  }
  return value.hashCode;
}

final class DirectConnectionProbe {
  const DirectConnectionProbe({
    required this.reachable,
    this.modelCount,
    this.message,
  });

  final bool reachable;
  final int? modelCount;
  final String? message;
}
