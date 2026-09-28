# `package:prebuilt_code_assets`

Shared build and link hook infrastructure for Dart packages that distribute prebuilt native code assets (via GitHub Releases or bundled `prebuilt/` directories), support compiling from source (`CMake`, `Cargo`, or `CBuilder`), and tree-shake static libraries in `hook/link.dart` via `@RecordUse`.

Modeled after `CLibrary` in `package:native_toolchain_c`, a single [`PrebuiltLibrary`](lib/src/prebuilt_library.dart) specification is defined once and shared across `hook/build.dart`, `hook/link.dart`, `tool/precompile_binaries.dart`, and `tool/regenerate_hashes.dart`.

## Features

- **Unified `PrebuiltLibrary` specification**:
  - `library.build(input: input, output: output)` for `hook/build.dart`.
  - `library.link(input: input, output: output)` for `hook/link.dart`.
  - `library.buildStandalone(...)` (via `BuildInputBuilder`) for standalone CI scripts.
- **Standardized `user_defines` build modes (`BuildOptions`)**:
  - `fetch` (default): Uses a pub-bundled `prebuilt/` binary if present, or downloads and caches the prebuilt binary in `outputDirectoryShared` (in an ABI-specific subdirectory preserving the canonical OS library filename for iOS/macOS XCFrameworks) and verifies its SHA-256 digest. Optionally falls back to `buildFromSource` on missing target or network failure.
  - `build` / `checkout`: Compiles from source using `buildFromSource`.
  - `local`: Bundles a pre-existing dynamic library from `localPath`.
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
import 'package:code_assets/code_assets.dart';
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
