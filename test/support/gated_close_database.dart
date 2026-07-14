import 'dart:async';

import 'package:conduit/core/database/app_database.dart';
import 'package:drift/native.dart';

/// Test database whose close can be observed, delayed, or made to fail.
final class GatedCloseDatabase extends AppDatabase {
  GatedCloseDatabase(super.executor, {this.failClose = true});

  GatedCloseDatabase.memory({this.failClose = true})
    : super(NativeDatabase.memory());

  bool failClose;
  int closeAttempts = 0;
  Completer<void>? closeGate;
  final closeStarted = Completer<void>();

  @override
  Future<void> close() async {
    closeAttempts += 1;
    if (!closeStarted.isCompleted) closeStarted.complete();
    final gate = closeGate;
    closeGate = null;
    if (gate != null) await gate.future;
    if (failClose) {
      throw StateError('injected close failure #$closeAttempts');
    }
    await super.close();
  }
}
