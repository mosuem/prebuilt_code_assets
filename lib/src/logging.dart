// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:io';

import 'package:logging/logging.dart';

/// The logger used when callers don't pass one.
///
/// A detached logger (so the global root logger is left untouched) with a
/// single listener, created once per isolate. Warnings and errors go to
/// stderr, everything else to stdout; both end up in the hook's log.
final Logger defaultLogger = Logger.detached('prebuilt_code_assets')
  ..level = Level.ALL
  ..onRecord.listen((record) {
    final sink = record.level >= Level.WARNING ? stderr : stdout;
    sink.writeln(record.message);
    if (record.error != null) sink.writeln(record.error);
    if (record.stackTrace != null) sink.writeln(record.stackTrace);
  });
