## 0.1.0

- Initial version:
  - `PrebuiltLibrary` specification for `hook/build.dart`, `hook/link.dart`, and standalone `BuildInputBuilder` builds.
  - `BuildOptions` and `BuildMode` (`fetch`, `build`, `checkout`, `local`) parsing for `hooks.user_defines`.
  - Prebuilt binary fetching with `outputDirectoryShared` ABI-subdirectory caching, pure-Dart SHA-256 verification, and bundled `prebuilt/` directory support.
  - Link-hook tree-shaking via `@RecordUse` (`SymbolsResolvers`), Windows COFF `.lib` symbol parsing, `.def` module-definition fallback, and automatic fallback to prebuilt dynamic libraries when linking fails.
  - Maintainer CLI runners (`runPrecompileBinariesCli`, `runRegenerateHashesCli`) and ELF `.dynsym` test helpers.
