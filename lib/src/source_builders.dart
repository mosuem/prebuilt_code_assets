// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:io';

import 'package:hooks/hooks.dart';

/// Callback that compiles the native library from source and returns the [Uri]
/// of the built static or dynamic library file.
///
/// This is the extension point for language- or project-specific toolchains
/// (for example `CBuilder` from `package:native_toolchain_c`, CMake, or Cargo).
/// Implementations should add the source files they read to
/// `output.dependencies` so the hook is re-run when they change (see
/// [findSourceBuildDependencies]).
typedef SourceBuildCallback =
    Future<Uri> Function(
      BuildInput input,
      BuildOutputBuilder output, {
      required bool static,
      Uri? checkoutPath,
    });

/// Default file extensions tracked as native source build dependencies.
const Set<String> defaultNativeSourceExtensions = {
  '.S',
  '.asm',
  '.c',
  '.cc',
  '.cmake',
  '.cpp',
  '.h',
  '.hpp',
  '.rs',
  'CMakeLists.txt',
  'Cargo.toml',
  'Cargo.lock',
};

/// Recursively collects source files matching [extensions] under
/// [relativeDirectories] (resolved against [root]) for
/// `BuildOutputBuilder.dependencies`.
Iterable<Uri> findSourceBuildDependencies(
  Uri root,
  List<String> relativeDirectories, {
  Set<String> extensions = defaultNativeSourceExtensions,
}) sync* {
  for (final rel in relativeDirectories) {
    final dir = Directory.fromUri(root.resolve(rel));
    if (!dir.existsSync()) continue;
    for (final entity in dir.listSync(recursive: true, followLinks: false)) {
      if (entity is! File) continue;
      if (extensions.any(entity.uri.path.endsWith)) {
        yield entity.uri;
      }
    }
  }
}
