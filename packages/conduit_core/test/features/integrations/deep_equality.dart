import 'package:checks/context.dart';
import 'package:collection/collection.dart';

extension DeepEquality on Subject<Object?> {
  /// Structural equality for decoded JSON, where the value is typed dynamic.
  void deepEquals(Object? expected) {
    context.expect(() => <String>['is deeply equal to $expected'], (actual) {
      return const DeepCollectionEquality().equals(actual, expected)
          ? null
          : Rejection(which: <String>['is $actual']);
    });
  }
}
