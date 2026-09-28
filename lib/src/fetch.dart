// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';

import 'release_config.dart';
import 'targets.dart';

/// Resolves or downloads the pre-built library for the target of [input] using
/// [releaseConfig], caching it in [HookInput.outputDirectoryShared] under an
/// ABI-specific subdirectory so the leaf filename matches the canonical OS
/// library name (required for iOS/macOS XCFrameworks).
///
/// If [prebuiltDirectory] is provided and a matching binary exists inside the
/// package at `<packageRoot>/<prebuiltDirectory>/`, it is staged into the
/// shared directory without making any network requests.
///
/// Returns `null` if no hash is registered in
/// [PrebuiltReleaseConfig.fileHashes] or if downloading fails due to an HTTP
/// or network error. Throws a [BuildError] if the downloaded file's SHA-256
/// checksum does not match [PrebuiltReleaseConfig.fileHashes].
Future<Uri?> fetchPrebuiltLibrary(
  HookInput input,
  PrebuiltReleaseConfig releaseConfig, {
  required bool static,
  String? prebuiltDirectory,
  String fallbackBuildModeName = 'checkout',
}) async {
  final targetOS = input.config.code.targetOS;
  final targetArch = input.config.code.targetArchitecture;
  final iosSdk = targetOS == OS.iOS ? input.config.code.iOS.targetSdk : null;
  final pkg = input.packageName;

  final assetRemoteName = releaseConfig.resolveAssetName(
    targetOS,
    targetArch,
    iosSdk: iosSdk,
    static: static,
  );
  final fileName = releaseConfig.resolveLibraryFileName(
    targetOS,
    static: static,
  );
  final cachedFile = File.fromUri(
    input.outputDirectoryShared
        .resolve('$pkg-${releaseConfig.version}/$assetRemoteName/')
        .resolve(fileName),
  );

  // 1. Check for a pub-bundled prebuilt binary in `prebuiltDirectory` first.
  if (prebuiltDirectory != null) {
    final triple = targetTripleFor(targetOS, targetArch, iosSdk: iosSdk);
    final candidates = [
      File.fromUri(
        input.packageRoot.resolve('$prebuiltDirectory/$assetRemoteName'),
      ),
      File.fromUri(
        input.packageRoot.resolve('$prebuiltDirectory/$triple/$fileName'),
      ),
    ];
    for (final bundledFile in candidates) {
      if (await bundledFile.exists()) {
        stdout.writeln(
          '$pkg: using bundled prebuilt binary (${bundledFile.path}).',
        );
        await cachedFile.parent.create(recursive: true);
        await bundledFile.copy(cachedFile.path);
        return cachedFile.uri;
      }
    }
  }

  // 2. Check registered SHA-256 hash.
  final expectedHash = releaseConfig.fileHashes[assetRemoteName];
  if (expectedHash == null || expectedHash.isEmpty) {
    stdout.writeln(
      '$pkg: no prebuilt binary hash registered for $assetRemoteName.',
    );
    return null;
  }

  // 3. Check shared cache directory.
  if (await cachedFile.exists()) {
    final cachedHash = sha256
        .convert(await cachedFile.readAsBytes())
        .toString();
    if (cachedHash == expectedHash) {
      stdout.writeln(
        '$pkg: using cached prebuilt binary ($assetRemoteName).',
      );
      return cachedFile.uri;
    }
  }

  // 4. Download from remote release URI.
  final binaryUrl = releaseConfig.resolveDownloadUri(
    releaseConfig.version,
    assetRemoteName,
  );

  stdout.writeln('$pkg: fetching prebuilt binary from $binaryUrl...');

  final client = HttpClient()..findProxy = HttpClient.findProxyFromEnvironment;
  final List<int> bytes;
  try {
    final request = await client.getUrl(binaryUrl);
    final response = await request.close();
    if (response.statusCode != 200) {
      stdout.writeln(
        '$pkg: failed to download from $binaryUrl '
        '(status: ${response.statusCode}).',
      );
      await response.drain<void>();
      return null;
    }
    bytes = await response.fold<List<int>>([], (a, b) => a..addAll(b));
  } on IOException catch (e) {
    stdout.writeln(
      '$pkg: network error downloading prebuilt binary ($e).',
    );
    return null;
  } finally {
    client.close();
  }

  final actualHash = sha256.convert(bytes).toString();

  if (actualHash != expectedHash) {
    throw BuildError(
      message:
          'SHA256 hash mismatch for prebuilt binary $assetRemoteName.\n'
          'Expected: $expectedHash\n'
          'Actual:   $actualHash\n'
          'To build $pkg locally from source instead, set '
          '`buildMode: $fallbackBuildModeName` in your pubspec.yaml under '
          '`hooks.user_defines.$pkg`.',
    );
  }

  stdout.writeln('$pkg: verified SHA256 checksum ($actualHash).');

  await cachedFile.parent.create(recursive: true);
  await cachedFile.writeAsBytes(bytes);
  return cachedFile.uri;
}
