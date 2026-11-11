// Build with `dart build cli -t tool/benchmark_chat_storage.dart`.
// File-backed synthetic history; setup and warmups are outside measurements.
import 'dart:convert';
import 'dart:io';

import 'package:conduit_core/database/app_database.dart';
import 'package:conduit_core/database/mappers/chat_blob_mapper.dart';
import 'package:drift/native.dart';

import '../packages/conduit_core/test/database/support/large_fixture.dart';

Future<void> main() async {
  final directory = await Directory.systemTemp.createTemp(
    'synthetic-chat-bench-',
  );
  final reports = <Object>[];
  String? sqliteVersion;
  try {
    for (final count in [500, 10000]) {
      final file = File('${directory.path}/history-$count.sqlite');
      var db = AppDatabase(NativeDatabase(file));
      sqliteVersion ??=
          (await db
                  .customSelect('SELECT sqlite_version() AS version')
                  .getSingle())
              .read<String>('version');
      final fixture = await seedAndBuildFts(db, bigChatMessages: count);
      var parent =
          '${fixture.bigChatId}-m${(count - 1).toString().padLeft(4, '0')}';
      for (final operation in ['page50', 'page200', 'append']) {
        stderr.writeln('Measuring $count / $operation');
        final samples = <double>[];
        for (var i = 0; i < 35; i++) {
          final clock = Stopwatch()..start();
          if (operation == 'append') {
            await db.chatsDao.appendMessagesWithUpdateOp(
              chatId: fixture.bigChatId,
              messages: [
                MessageRowData(
                  id: 'synthetic-append-$i',
                  chatId: fixture.bigChatId,
                  parentId: parent,
                  role: 'assistant',
                  content: 'A synthetic blue triangle has three sides.',
                  createdAt: 2500000 + i,
                  orderIndex: count + i,
                ),
              ],
              currentMessageId: 'synthetic-append-$i',
              enqueueCompletion: false,
            );
            parent = 'synthetic-append-$i';
          } else {
            final limit = operation == 'page50' ? 50 : 200;
            final page = await db.messagesDao.getActiveBranchPage(
              fixture.bigChatId,
              limit: limit,
            );
            if (page.primaryRows.length != limit) {
              throw StateError('Short page');
            }
          }
          clock.stop();
          if (i >= 5) samples.add(clock.elapsedMicroseconds / 1000);
        }
        reports.add({
          'operation': operation,
          'historyMessages': count,
          'milliseconds': describe(samples),
        });
      }
      await db.close();
      final samples = <double>[];
      for (var i = 0; i < 32; i++) {
        final clock = Stopwatch()..start();
        db = AppDatabase(NativeDatabase(file));
        final page = await db.chatsDao.getChatPage(limit: 200, offset: 0);
        clock.stop();
        if (page.length != 200) throw StateError('Short chat list');
        if (i >= 2) samples.add(clock.elapsedMicroseconds / 1000);
        await db.close();
      }
      reports.add({
        'operation': 'reopenAndList200',
        'historyMessages': count,
        'milliseconds': describe(samples),
      });
    }
    stdout.writeln(
      jsonEncode({
        'sqlite': sqliteVersion,
        'dart': Platform.version,
        'results': reports,
      }),
    );
  } finally {
    await directory.delete(recursive: true);
  }
}

Map<String, Object> describe(List<double> samples) {
  if (samples.isEmpty) {
    throw StateError('No measured samples; check warmup and iteration counts.');
  }
  samples.sort();
  double p(double q) => samples[(samples.length * q).ceil() - 1];
  return {
    'samples': samples.length,
    'p50': p(.5),
    'p95': p(.95),
    'p99': p(.99),
    'max': samples.last,
    'values': samples,
  };
}
