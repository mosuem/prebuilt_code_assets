// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';

import 'targets.dart';

/// Callback that compiles the native library from source and returns the [Uri]
/// of the built static or dynamic library file.
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

/// Reusable Rust/Cargo source builder (`cargo rustc --crate-type=...`) shared
/// by Rust FFI packages such as `package:icu4x` and `package:sigstore`.
class CargoSourceBuilder {
  /// The library stem name used to compute the output filename via
  /// `targetOS.staticlibFileName(libraryName)` or
  /// `targetOS.dylibFileName(libraryName)`.
  final String libraryName;

  /// Relative path to `Cargo.toml` within the checkout directory (defaults to
  /// `'Cargo.toml'`).
  final String manifestPath;

  /// Optional default subdirectory relative to `input.packageRoot` when
  /// `checkoutPath` is not provided in `hooks.user_defines` (e.g. `'rust/'`).
  /// If `null`, `checkoutPath` must be specified by the user.
  final String? defaultCheckoutSubdir;

  /// Cargo features to enable (`--features=...`).
  final List<String> features;

  /// Additional features to enable conditioned on whether the target is a
  /// `no_std` target (`riscv64`).
  final List<String> Function(bool isNoStd)? conditionalFeatures;

  /// Whether to pass `--no-default-features`.
  final bool noDefaultFeatures;

  /// Extra `--config=...` flags passed to `cargo rustc`.
  final List<String> cargoConfigFlags;

  /// If non-null, installs and uses this nightly Rust toolchain with
  /// `-Zbuild-std=std,panic_abort` when building a static library or `no_std`
  /// target (used by `package:icu4x`).
  final String? nightlyToolchainForStatic;

  /// Whether to automatically run `rustup target add <rustTarget>` before
  /// invoking `cargo rustc`.
  final bool ensureRustupTarget;

  const CargoSourceBuilder({
    required this.libraryName,
    this.manifestPath = 'Cargo.toml',
    this.defaultCheckoutSubdir,
    this.features = const [],
    this.conditionalFeatures,
    this.noDefaultFeatures = false,
    this.cargoConfigFlags = const [],
    this.nightlyToolchainForStatic,
    this.ensureRustupTarget = false,
  });

  static bool _isNoStdTarget(String rustTarget) => const {
    'riscv64-linux-android',
    'riscv64gc-unknown-linux-gnu',
  }.contains(rustTarget);

  /// Compiles the Rust crate for `input.config.code` and returns the output
  /// library [Uri].
  Future<Uri> build(
    BuildInput input,
    BuildOutputBuilder output, {
    required bool static,
    Uri? checkoutPath,
  }) async {
    final resolvedCheckout =
        checkoutPath ??
        (defaultCheckoutSubdir != null
            ? input.packageRoot.resolve(defaultCheckoutSubdir!)
            : null);
    if (resolvedCheckout == null) {
      throw BuildError(
        message:
            'Specify the Rust checkout folder with `checkoutPath` under '
            '`hooks.user_defines.${input.packageName}` in your pubspec.yaml.',
      );
    }

    final workingDir = Directory.fromUri(resolvedCheckout);
    final manifestFile = File.fromUri(workingDir.uri.resolve(manifestPath));
    if (!manifestFile.existsSync()) {
      throw BuildError(
        message: 'Could not find $manifestPath at ${manifestFile.path}.',
      );
    }

    final targetOS = input.config.code.targetOS;
    final outFileName = static
        ? targetOS.staticlibFileName(libraryName)
        : targetOS.dylibFileName(libraryName);
    final outUri = input.outputDirectory.resolve(outFileName);
    await File.fromUri(outUri).parent.create(recursive: true);

    final rustTarget = asRustTargetForConfig(input.config.code);
    final isNoStd = _isNoStdTarget(rustTarget);
    final nightly = nightlyToolchainForStatic != null && (static || isNoStd)
        ? (Platform.environment['PINNED_CI_NIGHTLY'] ??
              nightlyToolchainForStatic!)
        : null;

    if (nightly != null) {
      await _runProcess('rustup', [
        'toolchain',
        'install',
        '--no-self-update',
        nightly,
        '--component',
        'rust-src',
      ], workingDirectory: workingDir);
    }

    if (ensureRustupTarget || nightly != null) {
      await _runProcess('rustup', [
        'target',
        'add',
        rustTarget,
        if (nightly != null) ...['--toolchain', nightly],
      ], workingDirectory: workingDir);
    }

    final allFeatures = <String>{
      ...features,
      ...?conditionalFeatures?.call(isNoStd),
    };

    await _runProcess(
      'cargo',
      [
        if (nightly != null) '+$nightly',
        'rustc',
        '--manifest-path=${manifestFile.path}',
        '--crate-type=${static ? 'staticlib' : 'cdylib'}',
        '--release',
        ...cargoConfigFlags,
        if (noDefaultFeatures) '--no-default-features',
        if (allFeatures.isNotEmpty) '--features=${allFeatures.join(',')}',
        if (nightly != null && isNoStd) '-Zbuild-std=core,alloc',
        if (nightly != null) '-Zbuild-std=std,panic_abort',
        '--target=$rustTarget',
        '--',
        '--emit',
        'link=${outUri.toFilePath(windows: Platform.isWindows)}',
      ],
      workingDirectory: workingDir,
      environment: {
        if (nightly != null && isNoStd)
          'RUSTFLAGS': '-Zunstable-options -Cpanic=immediate-abort',
      },
    );

    final cargoLock = workingDir.uri.resolve('Cargo.lock');
    if (File.fromUri(cargoLock).existsSync()) {
      output.dependencies.add(cargoLock);
    } else {
      output.dependencies.add(manifestFile.uri);
    }

    return outUri;
  }

  static Future<void> _runProcess(
    String executable,
    List<String> arguments, {
    Directory? workingDirectory,
    Map<String, String>? environment,
  }) async {
    stdout.writeln('==> $executable ${arguments.join(' ')}');
    final result = await Process.run(
      executable,
      arguments,
      workingDirectory: workingDirectory?.path,
      environment: environment,
    );
    if (result.exitCode != 0) {
      throw ProcessException(
        executable,
        arguments,
        'stdout:\n${result.stdout}\nstderr:\n${result.stderr}',
        result.exitCode,
      );
    }
  }
}
