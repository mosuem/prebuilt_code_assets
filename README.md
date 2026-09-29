# `package:prebuilt_code_assets`

Shared build and link hook infrastructure for Dart packages that distribute prebuilt native code assets (via GitHub Releases or bundled `prebuilt/` directories), support compiling from source (`CMake`, `Cargo`, or `CBuilder`), and tree-shake static libraries in `hook/link.dart` via `@RecordUse`.

Modeled after `CLibrary` in `package:native_toolchain_c`, a single [`PrebuiltLibrary`](lib/src/prebuilt_library.dart) specification is defined once and shared across `hook/build.dart`, `hook/link.dart`, `tool/precompile_binaries.dart`, and `tool/regenerate_hashes.dart`.

## Features

- **Unified `PrebuiltLibrary` specification**:
  - `library.build(input: input, output: output)` for `hook/build.dart`.
  - `library.link(input: input, output: output)` for `hook/link.dart`.
  - `library.buildStandalone(...)` (via `BuildInputBuilder`) for standalone CI scripts.
- **Standardized `hooks.user_defines.<package_name>` build modes (`BuildOptions`)**:
  - Configured under `hooks.user_defines.<package_name>` in the consuming app's `pubspec.yaml` via the `buildMode` key (or `local_build: true`):
    - `buildMode: fetch` (default): Uses a pub-bundled `prebuilt/` binary if present, or downloads and caches the prebuilt binary in `outputDirectoryShared` (in an ABI-specific subdirectory preserving the canonical OS library filename for iOS/macOS XCFrameworks) and verifies its SHA-256 digest. Optionally falls back to `buildFromSource` on missing target or network failure.
    - `buildMode: build` / `buildMode: checkout`: Compiles from source using `buildFromSource` (optionally from `checkoutPath`).
    - `buildMode: local`: Bundles a pre-existing dynamic library from `localPath`.
- **Tree-shaking link hook (`hook/link.dart`) with automatic fallback**:
  - Resolves used symbols via `SymbolsResolvers.fromRecordUseMapping` (`ffigen`) or `SymbolsResolvers.fromMethodPrefix` (Diplomat).
  - Parses Windows COFF `.lib` archives to filter exported symbols and generates a `.def` module-definition file when `/INCLUDE:<symbol>` flags would exceed the Windows 32k command-line limit.
  - Automatically falls back to fetching the prebuilt dynamic library when linking fails in `fetch` mode (e.g. when cross-compiling without a target C linker or Android NDK).
- **Maintainer CLI runners (`package:prebuilt_code_assets/tools.dart`)**:
  - `runPrecompileBinariesCli` for `tool/precompile_binaries.dart`.
  - `runRegenerateHashesCli` for `tool/regenerate_hashes.dart` (supports both local artifact directories and remote GitHub Release URLs).

## Usage

### 1. Define your `PrebuiltLibrary` (`lib/src/hook_helpers/library.dart`)

```dart
import 'package:prebuilt_code_assets/prebuilt_code_assets.dart';
import 'package:record_use/record_use.dart' as record_use;

import '../bindings/record_use_mapping.g.dart';
import 'hashes.dart';

final myLibrary = PrebuiltLibrary(
  name: 'my_lib',
  assetName: 'my_package.dart',
  releaseConfig: PrebuiltReleaseConfig.github(
    owner: 'my-org',
    repo: 'my_package',
    version: version,
    fileHashes: fileHashes,
    libraryName: 'my_lib',
  ),
  buildFromSource: (input, output, {required static, checkoutPath}) async {
    // Compile via CMakeBuilder, CargoSourceBuilder, or CBuilder...
  },
  usedSymbols: SymbolsResolvers.fromRecordUseMapping(
    const record_use.Library('package:my_package/src/bindings/bindings.g.dart'),
    recordUseMapping,
  ),
  allKnownSymbols: recordUseMapping.values.toSet(),
);
```

### 2. Wire up `hook/build.dart` and `hook/link.dart`


```dart
// hook/build.dart
import 'package:hooks/hooks.dart';
import 'package:my_package/src/hook_helpers/library.dart';

Future<void> main(List<String> args) async {
  await build(args, (input, output) async {
    await myLibrary.build(input: input, output: output);
  });
}
```

```dart
// hook/link.dart
import 'package:hooks/hooks.dart';
import 'package:my_package/src/hook_helpers/library.dart';

Future<void> main(List<String> args) async {
  await link(args, (input, output) async {
    await myLibrary.link(input: input, output: output);
  });
}
```

### 3. Configuring `user_defines` in `pubspec.yaml`

Consumers of your package configure how the native library is obtained under `hooks.user_defines.<package_name>` in their workspace or application `pubspec.yaml`:

```yaml
hooks:
  user_defines:
    my_package:
      # 'fetch' (default), 'build', 'checkout', or 'local'
      buildMode: fetch
      # Path to a local source checkout (used when buildMode is 'build' or 'checkout')
      # checkoutPath: ../path/to/checkout
      # Path to a pre-existing dynamic library on disk (required when buildMode is 'local')
      # localPath: /absolute/or/relative/path/to/libmy_lib.so
```

| Key | Type | Description |
| :--- | :--- | :--- |
| `buildMode` | `String` | `'fetch'` (default: use bundled `prebuilt/` or download from release URL), `'build'` / `'checkout'` (compile from source), or `'local'` (use a binary at `localPath`). |
| `local_build` | `bool` | Shorthand boolean alias (`local_build: true` sets `buildMode: build`). |
| `checkoutPath` | `String` (path) | Optional path to a local source directory when `buildMode` is `'build'` or `'checkout'`. |
| `localPath` | `String` (path) | Path to a pre-built dynamic library file when `buildMode` is `'local'`. |

If `envVarPrefix` is set on `PrebuiltLibrary` (e.g. `envVarPrefix: 'MY_PKG'`), these options can also be overridden via environment variables:
- `<PREFIX>_BUILD_MODE`
- `<PREFIX>_CHECKOUT_PATH`
- `<PREFIX>_LOCAL_PATH`



