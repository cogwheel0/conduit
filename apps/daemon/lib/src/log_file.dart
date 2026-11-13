import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

/// The daemon's log on disk: `conduitd.log` in the logs directory, rolled
/// over to `conduitd.1.log` and on once it reaches [maxBytes], with at most
/// [keep] files in all.
///
/// The app captures stderr too, but a log of the daemon's own is what
/// "Export diagnostics" can zip without asking the app for anything.
/// Synchronous writes keep lines whole and in order; a line is small, and
/// the daemon logs a few a second at most.
///
/// Never throws: a log that fails is switched off, so a full disk does not
/// take the daemon down with it.
class RotatingLogFile {
  RotatingLogFile(
    this.directory, {
    this.baseName = 'conduitd',
    this.maxBytes = 2 * 1024 * 1024,
    this.keep = 3,
  }) : assert(keep >= 1);

  final Directory directory;
  final String baseName;
  final int maxBytes;
  final int keep;

  RandomAccessFile? _file;
  int _size = 0;
  bool _failed = false;

  /// The file [index] back: 0 is the current one.
  File fileAt(int index) => File(
    p.join(
      directory.path,
      index == 0 ? '$baseName.log' : '$baseName.$index.log',
    ),
  );

  /// The log files that exist, newest first.
  List<File> get files => <File>[
    for (var i = 0; i < keep; i++)
      if (fileAt(i).existsSync()) fileAt(i),
  ];

  void writeln(String line) {
    if (_failed) return;
    try {
      final bytes = utf8.encode('$line\n');
      final file = _file ??= _open();
      if (_size > 0 && _size + bytes.length > maxBytes) {
        _rotate();
      }
      (_file ?? file).writeFromSync(bytes);
      _size += bytes.length;
    } on Object {
      _failed = true;
      _closeQuietly();
    }
  }

  Future<void> close() async {
    final file = _file;
    _file = null;
    await file?.close();
  }

  RandomAccessFile _open() {
    directory.createSync(recursive: true);
    final file = fileAt(0).openSync(mode: FileMode.append);
    _size = file.lengthSync();
    return file;
  }

  void _rotate() {
    _closeQuietly();
    // Oldest first, so each rename lands on a name already moved out of the
    // way; the oldest kept file is replaced by the one before it.
    for (var i = keep - 1; i >= 1; i--) {
      final from = fileAt(i - 1);
      if (from.existsSync()) from.renameSync(fileAt(i).path);
    }
    if (keep == 1) {
      fileAt(0).writeAsBytesSync(const <int>[]);
    }
    _file = _open();
  }

  void _closeQuietly() {
    try {
      _file?.closeSync();
    } on Object {
      // Nothing to do about it.
    }
    _file = null;
  }
}
