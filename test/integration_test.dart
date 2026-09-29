// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

// End-to-end integration test that:
// 1. Precompiles a real C library into static (.a/.lib) and dynamic
//    (.so/.dylib/.dll) binaries via `PrebuiltLibrary.buildStandalone`.
// 2. Generates `hashes.dart` via `runRegenerateHashesCli` and serves the
//    binaries over a local HTTP server (simulating GitHub Releases).
// 3. Creates a consumer Dart package using `PrebuiltLibrary` in
//    `hook/build.dart` and `hook/link.dart` with `@RecordUse` + `@Native`.
// 4. Runs `dart run` (fetch mode, dynamic library download + SHA-256 check).
// 5. Runs `dart build cli` (fetch mode, static library download +
//    `hook/link.dart` tree-shaking via `@RecordUse`, verifying unused symbols
//    are stripped).
// 6. Runs `dart build cli` with a failing linker to verify automatic fallback
//    to the prebuilt dynamic library.
// 7. Runs `dart run` in `buildMode: build` (compiling from source) and
//    `buildMode: local` (bundling a local dynamic library).
@TestOn('linux || mac-os || windows')
@Timeout(Duration(minutes: 5))
library;

import 'dart:ffi';
import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:prebuilt_code_assets/prebuilt_code_assets.dart';
import 'package:prebuilt_code_assets/tools.dart';
import 'package:test/test.dart';

/// Single-quoted YAML scalar: backslashes (Windows paths) are literal, and
/// single quotes are escaped by doubling them.
String yamlString(String value) => "'${value.replaceAll("'", "''")}'";

void main() {
  late Directory workspaceDir;
  late Directory pkgDir;
  late Directory artifactsDir;
  late HttpServer server;
  late Uri serverBaseUri;

  final repoRoot = Directory.current.uri;
  final currentOS = OS.current;
  final currentArch = Architecture.current;
  final triple = targetTripleFor(currentOS, currentArch);
  final dylibFileName = currentOS.dylibFileName('math_lib');
  final staticFileName = currentOS.staticlibFileName('math_lib');
  final dylibAssetName = 'math_lib-$triple-$dylibFileName';
  final staticAssetName = 'math_lib-$triple-$staticFileName';

  PrebuiltReleaseConfig makeReleaseConfig(
    String version, {
    Map<String, String> hashes = const {},
  }) => PrebuiltReleaseConfig(
    version: version,
    fileHashes: hashes,
    resolveDownloadUri: (ver, assetName) =>
        Uri.parse('$serverBaseUri/$ver/$assetName'),
    resolveAssetName: (os, arch, {iosSdk, required static}) {
      final t = targetTripleFor(os, arch, iosSdk: iosSdk);
      final file = static
          ? os.staticlibFileName('math_lib')
          : os.dylibFileName('math_lib');
      return 'math_lib-$t-$file';
    },
    resolveLibraryFileName: (os, {required static}) => static
        ? os.staticlibFileName('math_lib')
        : os.dylibFileName('math_lib'),
  );

  Future<void> writePubspec({
    String? buildMode,
    String? treeshake,
    String? localPath,
    String? checkoutPath,
  }) async {
    final userDefines = StringBuffer();
    if (buildMode != null ||
        treeshake != null ||
        localPath != null ||
        checkoutPath != null) {
      userDefines.writeln('hooks:');
      userDefines.writeln('  user_defines:');
      userDefines.writeln('    math_pkg:');
      if (buildMode != null) {
        userDefines.writeln('      buildMode: ${yamlString(buildMode)}');
      }
      if (treeshake != null) {
        userDefines.writeln('      treeshake: ${yamlString(treeshake)}');
      }
      if (localPath != null) {
        userDefines.writeln('      localPath: ${yamlString(localPath)}');
      }
      if (checkoutPath != null) {
        userDefines.writeln('      checkoutPath: ${yamlString(checkoutPath)}');
      }
    }

    await File.fromUri(pkgDir.uri.resolve('pubspec.yaml')).writeAsString('''
name: math_pkg
version: 0.1.0
publish_to: none

environment:
  sdk: ^3.10.0

dependencies:
  code_assets: any
  hooks: any
  meta: any
  native_toolchain_c: any
  prebuilt_code_assets:
    path: ${yamlString(repoRoot.toFilePath())}
  record_use: any

$userDefines
''');
  }

  setUpAll(() async {
    workspaceDir = await Directory.systemTemp.createTemp(
      'prebuilt_code_assets_e2e_',
    );
    pkgDir = Directory.fromUri(workspaceDir.uri.resolve('math_pkg/'));
    artifactsDir = Directory.fromUri(workspaceDir.uri.resolve('artifacts/'));
    await pkgDir.create(recursive: true);
    await artifactsDir.create(recursive: true);

    // 1. Write C source with one used function (`math_add`) and one unused
    //    function (`math_unused_multiply`).
    final srcDir = Directory.fromUri(pkgDir.uri.resolve('src/'));
    await srcDir.create(recursive: true);
    await File.fromUri(srcDir.uri.resolve('math_lib.c')).writeAsString('''
#if defined(_WIN32)
#define EXPORT __declspec(dllexport)
#else
#define EXPORT __attribute__((visibility("default")))
#endif

EXPORT int math_add(int a, int b) {
  return a + b;
}

EXPORT int math_unused_multiply(int a, int b) {
  return a * b;
}
''');

    // 2. Precompile both static and dynamic libraries using
    //    `PrebuiltLibrary.buildStandalone`.
    final precompileSpec = PrebuiltLibrary(
      name: 'math_lib',
      packageName: 'math_pkg',
      assetName: 'math_pkg.dart',
      buildFromSource: (input, output, {required static, checkoutPath}) async {
        final tempOutput = BuildOutputBuilder();
        await CBuilder.library(
          name: 'math_lib',
          assetName: 'math_pkg.dart',
          sources: const ['src/math_lib.c'],
          linkModePreference: static
              ? LinkModePreference.static
              : LinkModePreference.dynamic,
        ).run(input: input, output: tempOutput);
        final built = BuildOutput(tempOutput.json);
        return built.assets.code.single.file!;
      },
    );

    final builtDylib = await precompileSpec.buildStandalone(
      targetOS: currentOS,
      targetArchitecture: currentArch,
      static: false,
      packageRoot: pkgDir.uri,
    );
    await File.fromUri(
      builtDylib,
    ).copy(artifactsDir.uri.resolve(dylibAssetName).toFilePath());

    final builtStatic = await precompileSpec.buildStandalone(
      targetOS: currentOS,
      targetArchitecture: currentArch,
      static: true,
      packageRoot: pkgDir.uri,
    );
    await File.fromUri(
      builtStatic,
    ).copy(artifactsDir.uri.resolve(staticAssetName).toFilePath());

    // 3. Serve the artifacts over a local HTTP server.
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    serverBaseUri = Uri.parse('http://127.0.0.1:${server.port}');
    server.listen((request) async {
      final name = request.uri.pathSegments.isEmpty
          ? ''
          : request.uri.pathSegments.last;
      final file = File.fromUri(artifactsDir.uri.resolve(name));
      if (file.existsSync()) {
        request.response.statusCode = 200;
        await request.response.addStream(file.openRead());
      } else {
        request.response.statusCode = 404;
      }
      await request.response.close();
    });

    // 4. Populate `math_pkg` files and generate `hashes.dart` using
    //    `runRegenerateHashesCli`.
    await writePubspec();

    final libDir = Directory.fromUri(pkgDir.uri.resolve('lib/'));
    final hookDir = Directory.fromUri(pkgDir.uri.resolve('hook/'));
    final binDir = Directory.fromUri(pkgDir.uri.resolve('bin/'));
    await libDir.create(recursive: true);
    await hookDir.create(recursive: true);
    await binDir.create(recursive: true);

    await runRegenerateHashesCli(
      ['0.1.0', artifactsDir.path],
      defaultVersion: '0.1.0',
      releaseConfigForVersion: makeReleaseConfig,
      hashesFilePath: libDir.uri.resolve('hashes.dart').toFilePath(),
      versionFilePath: null,
      targets: [(currentOS, currentArch, null)],
    );

    await File.fromUri(libDir.uri.resolve('bindings.dart')).writeAsString('''
@ffi.DefaultAsset('package:math_pkg/math_pkg.dart')
library;

import 'dart:ffi' as ffi;
import 'package:meta/meta.dart' as meta;

@meta.RecordUse()
@ffi.Native<ffi.Int32 Function(ffi.Int32, ffi.Int32)>(symbol: 'math_add')
external int mathAdd(int a, int b);

@meta.RecordUse()
@ffi.Native<ffi.Int32 Function(ffi.Int32, ffi.Int32)>(
  symbol: 'math_unused_multiply',
)
external int mathUnusedMultiply(int a, int b);
''');

    await File.fromUri(libDir.uri.resolve('library.dart')).writeAsString('''
import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';
import 'package:prebuilt_code_assets/prebuilt_code_assets.dart';
import 'package:record_use/record_use.dart' as record_use;

import 'hashes.dart';

const recordUseMapping = <String, String>{
  'mathAdd': 'math_add',
  'mathUnusedMultiply': 'math_unused_multiply',
};

final mathLibrary = PrebuiltLibrary(
  name: 'math_lib',
  packageName: 'math_pkg',
  assetName: 'math_pkg.dart',
  fallbackToBuildOnFetchFailure: false,
  releaseConfig: PrebuiltReleaseConfig(
    version: version,
    fileHashes: fileHashes,
    resolveDownloadUri: (ver, assetName) =>
        Uri.parse('$serverBaseUri/\$ver/\$assetName'),
    resolveAssetName: (os, arch, {iosSdk, required static}) {
      final triple = targetTripleFor(os, arch, iosSdk: iosSdk);
      final file = static
          ? os.staticlibFileName('math_lib')
          : os.dylibFileName('math_lib');
      return 'math_lib-\$triple-\$file';
    },
    resolveLibraryFileName: (os, {required static}) =>
        static ? os.staticlibFileName('math_lib') : os.dylibFileName('math_lib'),
  ),
  buildFromSource: (input, output, {required static, checkoutPath}) async {
    final tempOutput = BuildOutputBuilder();
    await CBuilder.library(
      name: 'math_lib',
      assetName: 'math_pkg.dart',
      sources: const ['src/math_lib.c'],
      linkModePreference: static
          ? LinkModePreference.static
          : LinkModePreference.dynamic,
    ).run(input: input, output: tempOutput);
    final built = BuildOutput(tempOutput.json);
    output.dependencies.addAll(built.dependencies);
    return built.assets.code.single.file!;
  },
  usedSymbols: SymbolsResolvers.fromRecordUseMapping(
    const record_use.Library('package:math_pkg/bindings.dart'),
    recordUseMapping,
  ),
  allKnownSymbols: recordUseMapping.values,
);
''');

    await File.fromUri(hookDir.uri.resolve('build.dart')).writeAsString('''
import 'package:hooks/hooks.dart';
import 'package:math_pkg/library.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await mathLibrary.build(input: input, output: output);
  });
}
''');

    await File.fromUri(hookDir.uri.resolve('link.dart')).writeAsString('''
import 'package:hooks/hooks.dart';
import 'package:math_pkg/library.dart';

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    await mathLibrary.link(input: input, output: output);
  });
}
''');

    await File.fromUri(binDir.uri.resolve('main.dart')).writeAsString('''
import 'package:math_pkg/bindings.dart';

void main() {
  print('Result: \${mathAdd(20, 22)}');
}
''');

    final pubGet = await Process.run(
      Platform.resolvedExecutable,
      ['pub', 'get'],
      workingDirectory: pkgDir.path,
    );
    expect(pubGet.exitCode, 0, reason: '${pubGet.stdout}\n${pubGet.stderr}');
  });

  tearDownAll(() async {
    await server.close(force: true);
    await workspaceDir.delete(recursive: true);
  });

  test(
    'runRegenerateHashesCli generates hashes.dart for static and dynamic '
    'binaries',
    () async {
      final hashesContent = await File.fromUri(
        pkgDir.uri.resolve('lib/hashes.dart'),
      ).readAsString();
      expect(hashesContent, contains(dylibAssetName));
      expect(hashesContent, contains(staticAssetName));
    },
  );

  test(
    'dart run downloads dynamic library, verifies hash, and calls FFI',
    () async {
      await writePubspec(buildMode: 'fetch');
      final result = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/main.dart'],
        workingDirectory: pkgDir.path,
      );
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('Result: 42'));
    },
  );

  test(
    'dart build cli downloads static library and tree-shakes unused symbols '
    'in hook/link.dart',
    () async {
      await writePubspec(buildMode: 'fetch');
      final outDir = await Directory.systemTemp.createTemp('math_pkg_cli_');
      addTearDown(() => outDir.delete(recursive: true));

      final build = await Process.run(
        Platform.resolvedExecutable,
        ['build', 'cli', '--target', 'bin/main.dart', '--output', outDir.path],
        workingDirectory: pkgDir.path,
      );
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');

      final bundle = outDir.uri.resolve('bundle/');
      final exe = bundle.resolve(
        'bin/main${Platform.isWindows ? '.exe' : ''}',
      );
      final runResult = await Process.run(exe.toFilePath(), []);
      expect(
        runResult.exitCode,
        0,
        reason: '${runResult.stdout}\n${runResult.stderr}',
      );
      expect(runResult.stdout, contains('Result: 42'));

      final bundledDylib = File.fromUri(bundle.resolve('lib/$dylibFileName'));
      expect(bundledDylib.existsSync(), isTrue);

      final dylib = DynamicLibrary.open(bundledDylib.path);
      addTearDown(dylib.close);
      expect(
        dylib.providesSymbol('math_add'),
        isTrue,
        reason: 'Used symbol math_add must be kept by hook/link.dart',
      );
      expect(
        dylib.providesSymbol('math_unused_multiply'),
        isFalse,
        reason:
            'Unused symbol math_unused_multiply must be tree-shaken by '
            'hook/link.dart',
      );
    },
  );

  test(
    'dart build cli respects treeshake: auto, treeshake: on, and '
    'treeshake: off',
    () async {
      // 1. treeshake: off -> bundles dynamic library directly without
      //    tree-shaking (both math_add and math_unused_multiply are present).
      await writePubspec(buildMode: 'fetch', treeshake: 'off');
      final offOutDir = await Directory.systemTemp.createTemp(
        'math_pkg_cli_treeshake_off_',
      );
      addTearDown(() => offOutDir.delete(recursive: true));

      final offBuild = await Process.run(
        Platform.resolvedExecutable,
        [
          'build',
          'cli',
          '--target',
          'bin/main.dart',
          '--output',
          offOutDir.path,
        ],
        workingDirectory: pkgDir.path,
      );
      expect(
        offBuild.exitCode,
        0,
        reason: '${offBuild.stdout}\n${offBuild.stderr}',
      );
      final offDylibFile = File.fromUri(
        offOutDir.uri.resolve('bundle/lib/$dylibFileName'),
      );
      final offDylib = DynamicLibrary.open(offDylibFile.path);
      addTearDown(offDylib.close);
      expect(offDylib.providesSymbol('math_add'), isTrue);
      expect(
        offDylib.providesSymbol('math_unused_multiply'),
        isTrue,
        reason: 'treeshake: off must not strip unused symbols',
      );

      // 2. Replace the static library with invalid archive bytes (and
      //    regenerate hashes.dart) to test `treeshake: auto` vs `treeshake: on`
      //    when linking fails.
      final staticFile = File.fromUri(
        artifactsDir.uri.resolve(staticAssetName),
      );
      final originalStaticBytes = await staticFile.readAsBytes();
      final hashesFile = File.fromUri(pkgDir.uri.resolve('lib/hashes.dart'));
      final originalHashesContent = await hashesFile.readAsString();
      addTearDown(() async {
        await staticFile.writeAsBytes(originalStaticBytes);
        await hashesFile.writeAsString(originalHashesContent);
      });

      await staticFile.writeAsString('not-a-valid-static-archive');
      await runRegenerateHashesCli(
        ['0.1.0', artifactsDir.path],
        defaultVersion: '0.1.0',
        releaseConfigForVersion: makeReleaseConfig,
        hashesFilePath: hashesFile.path,
        versionFilePath: null,
        targets: [(currentOS, currentArch, null)],
      );

      // Clear cached static binary in .dart_tool/hooks_runner/shared so the
      // corrupted static archive is fetched.
      final dartToolHooks = Directory.fromUri(
        pkgDir.uri.resolve('.dart_tool/hooks_runner/'),
      );
      if (dartToolHooks.existsSync()) {
        await dartToolHooks.delete(recursive: true);
      }

      // 2a. treeshake: auto (default) -> falls back to prebuilt dynamic library
      await writePubspec(buildMode: 'fetch', treeshake: 'auto');
      final outDir = await Directory.systemTemp.createTemp(
        'math_pkg_cli_fallback_',
      );
      addTearDown(() => outDir.delete(recursive: true));

      final build = await Process.run(
        Platform.resolvedExecutable,
        ['build', 'cli', '--target', 'bin/main.dart', '--output', outDir.path],
        workingDirectory: pkgDir.path,
      );
      expect(build.exitCode, 0, reason: '${build.stdout}\n${build.stderr}');

      final bundle = outDir.uri.resolve('bundle/');
      final exe = bundle.resolve(
        'bin/main${Platform.isWindows ? '.exe' : ''}',
      );
      final runResult = await Process.run(exe.toFilePath(), []);
      expect(
        runResult.exitCode,
        0,
        reason: '${runResult.stdout}\n${runResult.stderr}',
      );
      expect(runResult.stdout, contains('Result: 42'));

      final bundledDylib = File.fromUri(bundle.resolve('lib/$dylibFileName'));
      final dylib = DynamicLibrary.open(bundledDylib.path);
      addTearDown(dylib.close);
      expect(dylib.providesSymbol('math_add'), isTrue);
      expect(
        dylib.providesSymbol('math_unused_multiply'),
        isTrue,
        reason:
            'Fallback prebuilt dynamic library contains all symbols '
            '(un-treeshaken)',
      );

      // 2b. treeshake: on -> throws when linking fails instead of falling back
      await writePubspec(buildMode: 'fetch', treeshake: 'on');
      final onOutDir = await Directory.systemTemp.createTemp(
        'math_pkg_cli_treeshake_on_',
      );
      addTearDown(() => onOutDir.delete(recursive: true));

      final onBuild = await Process.run(
        Platform.resolvedExecutable,
        [
          'build',
          'cli',
          '--target',
          'bin/main.dart',
          '--output',
          onOutDir.path,
        ],
        workingDirectory: pkgDir.path,
      );
      expect(
        onBuild.exitCode,
        isNonZero,
        reason: 'treeshake: on must fail when linking fails',
      );
    },
  );

  test(
    'dart run in buildMode: build and buildMode: local works end-to-end',
    () async {
      // 1. buildMode: build (compiles from C source in hook/build.dart)
      await writePubspec(buildMode: 'build');
      final buildRun = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/main.dart'],
        workingDirectory: pkgDir.path,
      );
      expect(
        buildRun.exitCode,
        0,
        reason: '${buildRun.stdout}\n${buildRun.stderr}',
      );
      expect(buildRun.stdout, contains('Result: 42'));

      // 2. buildMode: local (bundles existing dylib from localPath)
      final localDylibPath = artifactsDir.uri
          .resolve(dylibAssetName)
          .toFilePath();
      await writePubspec(buildMode: 'local', localPath: localDylibPath);
      final localRun = await Process.run(
        Platform.resolvedExecutable,
        ['run', 'bin/main.dart'],
        workingDirectory: pkgDir.path,
      );
      expect(
        localRun.exitCode,
        0,
        reason: '${localRun.stdout}\n${localRun.stderr}',
      );
      expect(localRun.stdout, contains('Result: 42'));
    },
  );
}
