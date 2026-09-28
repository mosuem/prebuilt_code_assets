// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:io';

import 'package:args/args.dart';
import 'package:code_assets/code_assets.dart';

import '../prebuilt_library.dart';
import '../targets.dart';

/// CLI runner for `tool/precompile_binaries.dart` (or `tool/build.dart`).
///
/// Parses `--target-os`, `--target-arch`, `--ios-sdk`, `--compile-type`, and
/// `--out-dir`. For each requested compile type (`dynamic` and/or `static`),
/// invokes [PrebuiltLibrary.buildStandalone] (or [customBuilder] if provided)
/// and copies the built binary to `<outDir>/<releaseAssetName>`.
Future<void> runPrecompileBinariesCli(
  List<String> args, {
  required PrebuiltLibrary library,
  Uri? packageRoot,
  Uri? checkoutPath,
  Future<Uri> Function({
    required OS targetOS,
    required Architecture targetArch,
    required IOSSdk? iosSdk,
    required bool static,
    required Uri packageRoot,
  })?
  customBuilder,
}) async {
  final parser = ArgParser()
    ..addOption(
      'target-os',
      abbr: 'o',
      allowed: [...OS.values.map((o) => o.name), 'current'],
      defaultsTo: 'current',
      help: 'Target OS to build for.',
    )
    ..addOption(
      'target-arch',
      abbr: 'a',
      allowed: [...Architecture.values.map((a) => a.name), 'current'],
      defaultsTo: 'current',
      help: 'Target architecture to build for.',
    )
    ..addOption(
      'ios-sdk',
      abbr: 'i',
      allowed: IOSSdk.values.map((s) => s.type),
      help: 'Target iOS SDK (iphoneos or iphonesimulator).',
    )
    ..addOption(
      'compile-type',
      abbr: 't',
      allowed: const ['dynamic', 'static', 'both'],
      defaultsTo: 'both',
      help: 'Type of library to compile (dynamic, static, or both).',
    )
    ..addOption(
      'out-dir',
      abbr: 'd',
      defaultsTo: 'bin',
      help: 'Output directory for built release binaries.',
    );

  final ArgResults results;
  try {
    results = parser.parse(args);
  } catch (e) {
    stderr.writeln('Error parsing arguments: $e\n');
    stderr.writeln(parser.usage);
    exit(1);
  }

  final targetOS = results['target-os'] == 'current'
      ? OS.current
      : OS.fromString(results['target-os'] as String);
  final targetArch = results['target-arch'] == 'current'
      ? Architecture.current
      : Architecture.fromString(results['target-arch'] as String);
  final iosSdkStr = results['ios-sdk'] as String?;
  final iosSdk = iosSdkStr != null ? IOSSdk.fromString(iosSdkStr) : null;

  final compileType = results['compile-type'] as String;
  final staticModes = switch (compileType) {
    'dynamic' => const [false],
    'static' => const [true],
    _ => const [false, true],
  };

  final root = packageRoot ?? Directory.current.uri;
  final outDir = Directory.fromUri(root.resolve('${results['out-dir']}/'));
  await outDir.create(recursive: true);

  final targetTriple = targetTripleFor(targetOS, targetArch, iosSdk: iosSdk);
  stdout.writeln('==> Precompiling ${library.name} for $targetTriple...');

  final releaseConfig = library.releaseConfig;

  for (final static in staticModes) {
    final builtUri = customBuilder != null
        ? await customBuilder(
            targetOS: targetOS,
            targetArch: targetArch,
            iosSdk: iosSdk,
            static: static,
            packageRoot: root,
          )
        : await library.buildStandalone(
            targetOS: targetOS,
            targetArchitecture: targetArch,
            static: static,
            iOSSdk: iosSdk,
            packageRoot: root,
            checkoutPath: checkoutPath,
          );

    final assetName = releaseConfig != null
        ? releaseConfig.resolveAssetName(
            targetOS,
            targetArch,
            iosSdk: iosSdk,
            static: static,
          )
        : (static
              ? targetOS.staticlibFileName(library.name)
              : targetOS.dylibFileName(library.name));

    final releaseAsset = File.fromUri(outDir.uri.resolve(assetName));
    await File.fromUri(builtUri).copy(releaseAsset.path);
    stdout.writeln('==> Created release binary: ${releaseAsset.path}');
  }
}
