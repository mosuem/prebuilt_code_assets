// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:io';

import 'package:hooks/hooks.dart' show BuildError, HookInputUserDefines;

/// How the build hook should obtain the native library.
enum BuildMode {
  /// Use a prebuilt binary (from a bundled `prebuilt/` directory if present, or
  /// downloaded from a release URL and verified against SHA-256 hashes).
  fetch,

  /// Compile the native library from source in-tree or at `checkoutPath`.
  build,

  /// Alias for [build] used by packages that build from a local checkout
  /// (`checkoutPath`).
  checkout,

  /// Bundle a pre-existing dynamic library from `localPath` on disk.
  local,
}

/// Backwards-compatible alias for [BuildMode].
typedef BuildModeEnum = BuildMode;

/// How `hook/link.dart` should handle tree-shaking of the native library.
enum TreeshakeMode {
  /// Always attempt to tree-shake in `hook/link.dart`, and throw if linking
  /// fails.
  on,

  /// Never tree-shake; bundle the dynamic library directly without running the
  /// C linker.
  off,

  /// Attempt to tree-shake in `hook/link.dart`, and fall back to bundling the
  /// prebuilt dynamic library (printing a warning with the failure) if linking
  /// fails.
  auto,
}

/// Parsed user-defines configuration for native asset hooks.
class BuildOptions {
  final BuildMode buildMode;
  final TreeshakeMode treeshake;
  final Uri? localPath;
  final Uri? checkoutPath;

  const BuildOptions({
    required this.buildMode,
    this.treeshake = TreeshakeMode.auto,
    this.localPath,
    this.checkoutPath,
  });

  /// Parses [BuildOptions] from `input.userDefines` (and optional environment
  /// variables prefixed with [envVarPrefix], e.g. `'SIGSTORE'`).
  ///
  /// Also supports the boolean `local_build` user-define used by
  /// `dart-lang/native` examples (`local_build: true` maps to
  /// [BuildMode.build]).
  ///
  /// When [strict] is `true`, throws a [BuildError] if `buildMode` or
  /// `treeshake` is set to an unrecognized value. When `false` (the default),
  /// falls back to [defaultMode] / [defaultTreeshake].
  factory BuildOptions.fromDefines(
    HookInputUserDefines defines, {
    String? packageName,
    String? envVarPrefix,
    BuildMode defaultMode = BuildMode.fetch,
    TreeshakeMode defaultTreeshake = TreeshakeMode.auto,
    bool strict = false,
    Map<String, String>? environment,
  }) {
    final env = environment ?? Platform.environment;
    final pkg = packageName ?? '<package>';

    var modeString = defines['buildMode'] as String?;
    if (modeString == null && envVarPrefix != null) {
      modeString = env['${envVarPrefix}_BUILD_MODE'];
    }
    if (modeString == null) {
      final localBuildBool = defines['local_build'] as bool?;
      if (localBuildBool != null) {
        modeString = localBuildBool ? BuildMode.build.name : defaultMode.name;
      }
    }

    final BuildMode buildMode;
    if (modeString == null) {
      buildMode = defaultMode;
    } else {
      final matched = BuildMode.values
          .where((e) => e.name == modeString)
          .firstOrNull;
      if (matched != null) {
        buildMode = matched;
      } else if (strict) {
        throw BuildError(
          message:
              'Unknown buildMode "$modeString".\n\n'
              'Set `buildMode` to `fetch`, `build`, `checkout`, or `local` in '
              'your pubspec.yaml:\n'
              'hooks:\n'
              '  user_defines:\n'
              '    $pkg:\n'
              '      buildMode: fetch\n',
        );
      } else {
        buildMode = defaultMode;
      }
    }

    final rawTreeshake = defines['treeshake'];
    var treeshakeString = switch (rawTreeshake) {
      final String s => s,
      final bool b => b ? TreeshakeMode.on.name : TreeshakeMode.off.name,
      _ => null,
    };
    if (treeshakeString == null && envVarPrefix != null) {
      treeshakeString = env['${envVarPrefix}_TREESHAKE'];
    }

    final TreeshakeMode treeshake;
    if (treeshakeString == null) {
      treeshake = defaultTreeshake;
    } else {
      final normalized = switch (treeshakeString.toLowerCase()) {
        'true' => TreeshakeMode.on.name,
        'false' => TreeshakeMode.off.name,
        final s => s,
      };
      final matched = TreeshakeMode.values
          .where((e) => e.name == normalized)
          .firstOrNull;
      if (matched != null) {
        treeshake = matched;
      } else if (strict) {
        throw BuildError(
          message:
              'Unknown treeshake mode "$treeshakeString".\n\n'
              'Set `treeshake` to `on`, `off`, or `auto` in your '
              'pubspec.yaml:\n'
              'hooks:\n'
              '  user_defines:\n'
              '    $pkg:\n'
              '      treeshake: auto\n',
        );
      } else {
        treeshake = defaultTreeshake;
      }
    }

    var localPath = defines.path('localPath');
    if (localPath == null && envVarPrefix != null) {
      final envLocal = env['${envVarPrefix}_LOCAL_PATH'];
      if (envLocal != null && envLocal.isNotEmpty) {
        localPath = Uri.file(envLocal);
      }
    }

    var checkoutPath = defines.path('checkoutPath');
    if (checkoutPath == null && envVarPrefix != null) {
      final envCheckout = env['${envVarPrefix}_CHECKOUT_PATH'];
      if (envCheckout != null && envCheckout.isNotEmpty) {
        checkoutPath = Uri.directory(envCheckout);
      }
    }

    return BuildOptions(
      buildMode: buildMode,
      treeshake: treeshake,
      localPath: localPath,
      checkoutPath: checkoutPath,
    );
  }

  /// Whether [buildMode] requests building from source ([BuildMode.build] or
  /// [BuildMode.checkout]).
  bool get isSourceBuild =>
      buildMode == BuildMode.build || buildMode == BuildMode.checkout;

  @override
  String toString() =>
      'BuildOptions(buildMode: $buildMode, treeshake: $treeshake, '
      'localPath: $localPath, checkoutPath: $checkoutPath)';
}
