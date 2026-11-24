import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';

import 'package:ffi/ffi.dart';

@Native<Pointer<Utf8> Function(Pointer<Utf8>)>(symbol: 'conduit_tailnet_call')
external Pointer<Utf8> _call(Pointer<Utf8> command);

@Native<Void Function(Pointer<Utf8>)>(symbol: 'conduit_tailnet_free')
external void _free(Pointer<Utf8> response);

/// Startup, remote dial and shutdown can block. They never run on the UI isolate.
Future<Map<String, dynamic>> callTailnet(Map<String, Object> request) =>
    Isolate.run(() {
      final input = jsonEncode(request).toNativeUtf8();
      try {
        final output = _call(input);
        try {
          final value =
              jsonDecode(output.toDartString()) as Map<String, dynamic>;
          if (value.containsKey('error')) {
            throw StateError('Tailscale is unavailable');
          }
          return value;
        } finally {
          _free(output);
        }
      } finally {
        malloc.free(input);
      }
    });
