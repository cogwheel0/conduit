import 'dart:io';

import 'release_notes_validator.dart';

void main(List<String> args) {
  final version = _readVersionArg(args);
  if (version == null) {
    stderr.writeln(
      'Usage: dart tool/validate_release_notes.dart --version x.y.z',
    );
    exitCode = 64;
    return;
  }

  final result = validateReleaseNotes(
    version: version,
    arbDirectory: Directory('lib/l10n'),
    notesDirectory: Directory('assets/release_notes'),
  );
  if (result.isValid) {
    stdout.writeln('Release notes validated for $version.');
    return;
  }

  stderr.writeln('Release notes validation failed for $version:');
  for (final error in result.errors) {
    stderr.writeln('- $error');
  }
  exitCode = 1;
}

String? _readVersionArg(List<String> args) {
  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--version' && i + 1 < args.length) {
      return args[i + 1].trim();
    }
    if (arg.startsWith('--version=')) {
      return arg.substring('--version='.length).trim();
    }
  }
  if (args.length == 1 && !args.first.startsWith('-')) {
    return args.first.trim();
  }
  return null;
}
