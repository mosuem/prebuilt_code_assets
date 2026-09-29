// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:logging/logging.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart' hide BuildMode;

import 'build_options.dart';
import 'coff_archive.dart';
import 'fetch.dart';
import 'release_config.dart';
import 'source_builders.dart';
import 'symbols_resolver.dart';

/// Declarative specification for building, fetching, and tree-shaking a native
/// library across `hook/build.dart`, `hook/link.dart`, and standalone
/// maintainer scripts.
///
/// Modeled after `CLibrary` in `package:native_toolchain_c`, a single
/// [PrebuiltLibrary] instance can be defined in `lib/src/hook_helpers/` and
/// invoked from:
/// - `hook/build.dart` via [build]
/// - `hook/link.dart` via [link]
/// - `tool/precompile_binaries.dart` via [buildStandalone]
class PrebuiltLibrary {
  /// The library stem name passed to `OS.dylibFileName` and `CLinker.library`
  /// (e.g. `'bssl_dart'`, `'icu4x'`, `'sigstore_dart'`).
  final String name;

  /// Optional package name override. Defaults to `input.packageName`.
  final String? packageName;

  /// The `@Native` asset ID suffix (e.g. `'boring.dart'` or
  /// `'src/bindings/lib.g.dart'`).
  final String assetName;

  /// Configuration for fetching and verifying prebuilt release binaries.
  final PrebuiltReleaseConfig? releaseConfig;

  /// Optional directory relative to `input.packageRoot` containing pub-bundled
  /// prebuilt binaries (e.g. `'prebuilt'`, following `prebuilt_assets_example`
  /// in `package:hooks`).
  final String? prebuiltDirectory;

  /// Callback to compile the native library from source when `buildMode` is
  /// `build`/`checkout` or when `fetch` falls back to building from source.
  final SourceBuildCallback? buildFromSource;

  /// Whether `fetch` mode should fall back to [buildFromSource] if no hash is
  /// registered for the target or if downloading fails.
  final bool fallbackToBuildOnFetchFailure;

  /// Optional environment variable prefix (e.g. `'SIGSTORE'`) for overriding
  /// `buildMode`, `localPath`, and `checkoutPath`.
  final String? envVarPrefix;

  /// Whether unrecognized `buildMode` values in `hooks.user_defines` should
  /// throw a [BuildError] instead of defaulting to [BuildMode.fetch].
  final bool strictBuildOptions;

  /// Extracts the native symbols used by the application from
  /// `LinkInput.recordedUses`.
  final SymbolsResolver? usedSymbols;

  /// Optional set of all bound symbol names (used on Windows when
  /// `LinkInput.recordedUses` is `null` or when filtering COFF archive
  /// symbols).
  final Iterable<String>? allKnownSymbols;

  /// Optional callback returning system libraries to link against in [link] for
  /// a given target [OS].
  final List<String> Function(OS targetOS)? libraries;

  /// Frameworks to link against in [link] (defaults to `const []`).
  final List<String> frameworks;

  /// Optimization level passed to `CLinker.library` in [link].
  final OptimizationLevel optimizationLevel;

  /// Optional [CLibrary] from `package:native_toolchain_c` used for building
  /// from source and linking when created via [PrebuiltLibrary.fromCLibrary].
  final CLibrary? cLibrary;

  const PrebuiltLibrary({
    required this.name,
    this.packageName,
    required this.assetName,
    this.releaseConfig,
    this.prebuiltDirectory,
    this.buildFromSource,
    this.fallbackToBuildOnFetchFailure = true,
    this.envVarPrefix,
    this.strictBuildOptions = false,
    this.usedSymbols,
    this.allKnownSymbols,
    this.libraries,
    this.frameworks = const [],
    this.optimizationLevel = OptimizationLevel.o3,
  }) : cLibrary = null;

  /// Creates a [PrebuiltLibrary] backed by a [CLibrary] from
  /// `package:native_toolchain_c`, avoiding duplication of [name],
  /// [packageName], [assetName], [frameworks], [libraries],
  /// [optimizationLevel], and C compiler/linker settings.
  PrebuiltLibrary.fromCLibrary(
    CLibrary this.cLibrary, {
    String? assetName,
    this.releaseConfig,
    this.prebuiltDirectory,
    SourceBuildCallback? buildFromSource,
    this.fallbackToBuildOnFetchFailure = true,
    this.envVarPrefix,
    this.strictBuildOptions = false,
    this.usedSymbols,
    this.allKnownSymbols,
    this.libraries,
  }) : name = cLibrary.name,
       packageName = cLibrary.packageName,
       assetName = assetName ?? cLibrary.assetName ?? cLibrary.name,
       frameworks = cLibrary.frameworks,
       optimizationLevel = cLibrary.optimizationLevel,
       buildFromSource =
           buildFromSource ?? _sourceBuilderFromCLibrary(cLibrary);

  static SourceBuildCallback _sourceBuilderFromCLibrary(CLibrary cLibrary) =>
      (input, output, {required static, checkoutPath}) async {
        final tempOutput = BuildOutputBuilder();
        await cLibrary.build(
          input: input,
          output: tempOutput,
          routing: const [ToAppBundle()],
          linkModePreference: static
              ? LinkModePreference.static
              : LinkModePreference.dynamic,
        );
        final built = BuildOutput(tempOutput.json);
        output.dependencies.addAll(built.dependencies);
        final codeAsset = built.assets.code.firstOrNull;
        final file = codeAsset?.file;
        if (file == null) {
          throw BuildError(
            message:
                'CLibrary(${cLibrary.name}).build did not emit a CodeAsset '
                'with a file.',
          );
        }
        return file;
      };

  /// Runs the build hook (`hook/build.dart`) for this library.
  ///
  /// When linking is enabled (`input.config.linkingEnabled`) and `buildMode` is
  /// not [BuildMode.local], obtains a static library (`StaticLinking()`) and
  /// routes it to `ToLinkHook(packageName)`. Otherwise obtains a dynamic
  /// library (`DynamicLoadingBundled()`) and routes it to `ToAppBundle()`.
  Future<void> build({
    required BuildInput input,
    required BuildOutputBuilder output,
    List<Uri> additionalDependencies = const [],
  }) async {
    final pkg = packageName ?? input.packageName;
    if (!input.config.buildCodeAssets) {
      stdout.writeln(
        '$pkg: skipping native asset build (code assets not requested).',
      );
      return;
    }

    final buildOptions = BuildOptions.fromDefines(
      input.userDefines,
      packageName: pkg,
      envVarPrefix: envVarPrefix,
      strict: strictBuildOptions,
    );
    stdout.writeln('$pkg: build options: $buildOptions');

    final static =
        buildOptions.buildMode != BuildMode.local &&
        (input.config.linkingEnabled ||
            input.config.code.linkModePreference == LinkModePreference.static);

    switch (buildOptions.buildMode) {
      case BuildMode.fetch:
        await _fetchOrFallback(
          input,
          output,
          pkg: pkg,
          static: static,
          checkoutPath: buildOptions.checkoutPath,
        );
      case BuildMode.build:
      case BuildMode.checkout:
        final builtUri = await _requireBuildFromSource(
          input,
          output,
          pkg: pkg,
          static: static,
          checkoutPath: buildOptions.checkoutPath,
        );
        _addLibrary(input, output, pkg: pkg, library: builtUri, static: static);
      case BuildMode.local:
        await _useLocalBinary(
          input,
          output,
          pkg: pkg,
          localPath: buildOptions.localPath,
        );
    }

    output.dependencies.addAll([
      input.packageRoot.resolve('pubspec.yaml'),
      input.packageRoot.resolve('hook/build.dart'),
      ...additionalDependencies,
    ]);
  }

  Future<void> _fetchOrFallback(
    BuildInput input,
    BuildOutputBuilder output, {
    required String pkg,
    required bool static,
    required Uri? checkoutPath,
  }) async {
    final config = releaseConfig;
    if (config == null) {
      if (buildFromSource != null) {
        final builtUri = await buildFromSource!(
          input,
          output,
          static: static,
          checkoutPath: checkoutPath,
        );
        _addLibrary(input, output, pkg: pkg, library: builtUri, static: static);
        return;
      }
      throw BuildError(
        message:
            '$pkg: neither `releaseConfig` nor `buildFromSource` is '
            'configured on PrebuiltLibrary.',
      );
    }

    final cachedLibrary = await fetchPrebuiltLibrary(
      input,
      config,
      static: static,
      prebuiltDirectory: prebuiltDirectory,
    );
    if (cachedLibrary != null) {
      _addLibrary(
        input,
        output,
        pkg: pkg,
        library: cachedLibrary,
        static: static,
      );
      return;
    }

    if (fallbackToBuildOnFetchFailure && buildFromSource != null) {
      stdout.writeln('$pkg: falling back to building from local source.');
      final builtUri = await buildFromSource!(
        input,
        output,
        static: static,
        checkoutPath: checkoutPath,
      );
      _addLibrary(input, output, pkg: pkg, library: builtUri, static: static);
      return;
    }

    final code = input.config.code;
    throw BuildError(
      message:
          '$pkg: failed to fetch prebuilt binary for '
          '${code.targetOS}-${code.targetArchitecture} (static: $static).',
    );
  }

  Future<Uri> _requireBuildFromSource(
    BuildInput input,
    BuildOutputBuilder output, {
    required String pkg,
    required bool static,
    required Uri? checkoutPath,
  }) async {
    if (buildFromSource == null) {
      throw BuildError(
        message:
            '$pkg: buildMode requires building from source, but '
            '`buildFromSource` is not configured.',
      );
    }
    return buildFromSource!(
      input,
      output,
      static: static,
      checkoutPath: checkoutPath,
    );
  }

  Future<void> _useLocalBinary(
    BuildInput input,
    BuildOutputBuilder output, {
    required String pkg,
    required Uri? localPath,
  }) async {
    if (localPath == null) {
      throw BuildError(
        message:
            'buildMode is set to `local`, but `localPath` was not specified '
            'under `hooks.user_defines.$pkg`.',
      );
    }
    final file = File.fromUri(localPath);
    if (!file.existsSync()) {
      throw BuildError(
        message:
            'Specified local binary does not exist at '
            '${localPath.toFilePath()}',
      );
    }
    final dylibFileName = input.config.code.targetOS.dylibFileName(name);
    final destFile = File.fromUri(input.outputDirectory.resolve(dylibFileName));
    await destFile.parent.create(recursive: true);
    await file.copy(destFile.path);

    _addLibrary(
      input,
      output,
      pkg: pkg,
      library: destFile.uri,
      static: false,
    );
    output.dependencies.add(localPath);
  }

  void _addLibrary(
    BuildInput input,
    BuildOutputBuilder output, {
    required String pkg,
    required Uri library,
    required bool static,
  }) {
    output.assets.code.add(
      CodeAsset(
        package: pkg,
        name: assetName,
        linkMode: static ? StaticLinking() : DynamicLoadingBundled(),
        file: library,
      ),
      routing: static ? ToLinkHook(input.packageName) : const ToAppBundle(),
    );
  }

  /// Runs the link hook (`hook/link.dart`) to link and tree-shake the static
  /// library emitted by [build] into a dynamic library containing only the
  /// functions referenced in `input.recordedUses`.
  ///
  /// If linking fails (e.g. because no cross-compilation C toolchain or Android
  /// NDK is installed) and `buildMode` is [BuildMode.fetch], automatically
  /// falls back to fetching and bundling the prebuilt dynamic library.
  Future<void> link({
    required LinkInput input,
    required LinkOutputBuilder output,
    Logger? logger,
  }) async {
    final pkg = packageName ?? input.packageName;
    final expectedId = 'package:$pkg/$assetName';
    final staticLibrary = input.assets.code
        .where(
          (asset) => asset.id == expectedId || asset.id.endsWith(assetName),
        )
        .firstOrNull;
    if (staticLibrary == null) {
      // hook/build.dart bundled a dynamic library directly.
      return;
    }
    final staticLibraryFile = staticLibrary.file!;

    final recordedUses = input.recordedUses;
    final List<String>? symbols;
    if (recordedUses == null || usedSymbols == null) {
      stdout.writeln('$pkg: no recorded uses, keeping all functions.');
      symbols = null;
    } else {
      symbols = usedSymbols!(recordedUses);
      stdout.writeln(
        '$pkg: keeping the ${symbols.length} functions the application '
        'uses:\n  ${symbols.join('\n  ')}',
      );
    }

    final LinkerOptions linkerOptions;
    if (input.config.code.targetOS == OS.windows) {
      linkerOptions = await createWindowsLinkerOptions(
        outputDirectory: input.outputDirectory,
        libraryName: name,
        staticLibrary: staticLibraryFile,
        symbols: symbols,
        allKnownSymbols: allKnownSymbols,
      );
    } else {
      linkerOptions = LinkerOptions.treeshake(symbolsToKeep: symbols);
    }

    try {
      final cLib = cLibrary;
      final resolvedLibraries = <String>[
        ...?cLib?.libraries,
        ...?libraries?.call(input.config.code.targetOS),
      ];
      await CLinker.library(
        name: name,
        packageName: pkg,
        assetName: assetName,
        sources: [staticLibraryFile.toFilePath()],
        includes: cLib?.includes ?? const [],
        forcedIncludes: cLib?.forcedIncludes ?? const [],
        frameworks: frameworks,
        libraries: resolvedLibraries,
        libraryDirectories: cLib?.libraryDirectories ?? const ['.'],
        flags: cLib?.flags ?? const [],

        defines: cLib?.defines ?? const {},
        pic: cLib?.pic ?? true,
        std: cLib?.std,
        language: cLib?.language ?? Language.c,
        cppLinkStdLib: cLib?.cppLinkStdLib,
        optimizationLevel: optimizationLevel,
        linkerOptions: linkerOptions,
        linkModePreference: LinkModePreference.dynamic,
      ).run(
        input: input,
        output: output,
        logger:
            logger ??
            (Logger('')
              ..level = Level.ALL
              ..onRecord.listen((record) => stdout.writeln(record.message))),
      );
    } catch (e, s) {
      // Tree-shaking only makes the library smaller, so a missing or broken C
      // toolchain should not fail the build if there is an equivalent
      // pre-built dynamic library. This also catches Error (such as ToolError).
      stdout.writeln('$pkg: linking failed: $e\n$s');
      final fellBack = await _fallBackToPrebuiltLibrary(
        input,
        output,
        pkg: pkg,
        error: e,
      );
      if (!fellBack) {
        rethrow;
      }
    }
  }

  Future<bool> _fallBackToPrebuiltLibrary(
    LinkInput input,
    LinkOutputBuilder output, {
    required String pkg,
    required Object error,
  }) async {
    final code = input.config.code;
    final target = '${code.targetOS}_${code.targetArchitecture}';
    final buildMode = BuildOptions.fromDefines(
      input.userDefines,
      packageName: pkg,
      envVarPrefix: envVarPrefix,
    ).buildMode;

    if (buildMode != BuildMode.fetch) {
      stderr.writeln(
        'package:$pkg could not link the static library built in the '
        '`${buildMode.name}` build mode for $target. Install a C toolchain '
        '(compiler and linker) for $target. Only the `fetch` build mode falls '
        'back to the pre-built dynamic library, which could differ from the '
        'library built in other modes.',
      );
      return false;
    }

    final config = releaseConfig;
    if (config == null) {
      return false;
    }

    final library = await fetchPrebuiltLibrary(
      input,
      config,
      static: false,
      prebuiltDirectory: prebuiltDirectory,
    );
    if (library == null) {
      return false;
    }

    final reason = switch (error) {
      ProcessException(:final executable) =>
        'ProcessException: $executable failed',
      _ => error.toString().split('\n').first,
    };
    stderr.writeln(
      'Warning: package:$pkg could not tree-shake its native library for '
      '$target, so it bundles the pre-built dynamic library of the $pkg '
      '${config.version} release instead, which is not tree-shaken and '
      'therefore larger. To enable tree-shaking, install a C toolchain '
      '(compiler and linker) for $target. Linking failed with: $reason',
    );
    output.assets.code.add(
      CodeAsset(
        package: pkg,
        name: assetName,
        linkMode: DynamicLoadingBundled(),
        file: library,
      ),
    );
    return true;
  }

  /// Synthesizes a [BuildInput] via [BuildInputBuilder] (following the
  /// `download_asset/tool/build.dart` pattern in `package:hooks`) and invokes
  /// [buildFromSource] for standalone precompilation in CI scripts.
  Future<Uri> buildStandalone({
    required OS targetOS,
    required Architecture targetArchitecture,
    required bool static,
    IOSSdk? iOSSdk,
    Uri? packageRoot,
    Uri? outputDirectory,
    Uri? outputDirectoryShared,
    Uri? checkoutPath,
    int androidTargetNdkApi = 28,
    int iOSTargetVersion = 13,
    int macOSTargetVersion = 13,
  }) async {
    if (buildFromSource == null) {
      throw StateError(
        'Cannot call buildStandalone when `buildFromSource` is null.',
      );
    }
    final root = packageRoot ?? Directory.current.uri;
    final pkg = packageName ?? name;
    final outDir =
        outputDirectory ??
        root.resolve(
          '.dart_tool/prebuilt_code_assets/'
          '${targetOS.name}_${targetArchitecture.name}_${static ? "static" : "dynamic"}/',
        );
    final sharedDir =
        outputDirectoryShared ??
        root.resolve('.dart_tool/prebuilt_code_assets/shared/');
    final outFile = outDir.resolve('output.json');

    await Directory.fromUri(outDir).create(recursive: true);
    await Directory.fromUri(sharedDir).create(recursive: true);

    final inputBuilder = BuildInputBuilder()
      ..setupShared(
        packageRoot: root,
        packageName: pkg,
        outputFile: outFile,
        outputDirectoryShared: sharedDir,
      )
      ..config.setupBuild(linkingEnabled: static)
      ..addExtension(
        CodeAssetExtension(
          targetArchitecture: targetArchitecture,
          targetOS: targetOS,
          linkModePreference: static
              ? LinkModePreference.static
              : LinkModePreference.dynamic,
          android: targetOS != OS.android
              ? null
              : AndroidCodeConfig(targetNdkApi: androidTargetNdkApi),
          iOS: targetOS != OS.iOS
              ? null
              : IOSCodeConfig(
                  targetSdk: iOSSdk ?? IOSSdk.iPhoneOS,
                  targetVersion: iOSTargetVersion,
                ),
          macOS: MacOSCodeConfig(targetVersion: macOSTargetVersion),
        ),
      );

    final input = inputBuilder.build();
    final output = BuildOutputBuilder();
    return buildFromSource!(
      input,
      output,
      static: static,
      checkoutPath: checkoutPath,
    );
  }
}
