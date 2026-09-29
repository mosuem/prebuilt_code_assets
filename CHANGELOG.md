## 0.1.1

- Added `PrebuiltLibrary.fromCLibrary` to reuse `CLibrary` metadata and compiler/linker configuration from `package:native_toolchain_c` without duplication.
- Re-exported `CLibrary`, `Language`, and `OptimizationLevel` from `package:prebuilt_code_assets/prebuilt_code_assets.dart`.
- Documented `hooks.user_defines.<package_name>` keys (`buildMode`, `local_build`, `checkoutPath`, `localPath`) and environment variable overrides in `README.md`.

## 0.1.0


- Initial version:
  - `PrebuiltLibrary` specification for `hook/build.dart`, `hook/link.dart`, and standalone `BuildInputBuilder` builds.
  - `BuildOptions` and `BuildMode` (`fetch`, `build`, `checkout`, `local`) parsing for `hooks.user_defines`.
  - Prebuilt binary fetching with `outputDirectoryShared` ABI-subdirectory caching, pure-Dart SHA-256 verification, and bundled `prebuilt/` directory support.
  - Link-hook tree-shaking via `@RecordUse` (`SymbolsResolvers`), Windows COFF `.lib` symbol parsing, `.def` module-definition fallback, and automatic fallback to prebuilt dynamic libraries when linking fails.
  - Maintainer CLI runners (`runPrecompileBinariesCli`, `runRegenerateHashesCli`) and ELF `.dynsym` test helpers.
