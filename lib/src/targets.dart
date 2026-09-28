// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'package:code_assets/code_assets.dart';

/// A target tuple consisting of [OS], [Architecture], and optional [IOSSdk].
typedef TargetSpec = (OS os, Architecture arch, IOSSdk? iosSdk);

/// Canonical list of supported native targets across mobile and desktop
/// platforms.
const List<TargetSpec> supportedTargets = [
  (OS.android, Architecture.arm, null),
  (OS.android, Architecture.arm64, null),
  (OS.android, Architecture.ia32, null),
  (OS.android, Architecture.riscv64, null),
  (OS.android, Architecture.x64, null),
  (OS.iOS, Architecture.arm64, IOSSdk.iPhoneOS),
  (OS.iOS, Architecture.arm64, IOSSdk.iPhoneSimulator),
  (OS.iOS, Architecture.x64, IOSSdk.iPhoneSimulator),
  (OS.linux, Architecture.arm, null),
  (OS.linux, Architecture.arm64, null),
  (OS.linux, Architecture.ia32, null),
  (OS.linux, Architecture.riscv64, null),
  (OS.linux, Architecture.x64, null),
  (OS.macOS, Architecture.arm64, null),
  (OS.macOS, Architecture.x64, null),
  (OS.windows, Architecture.arm64, null),
  (OS.windows, Architecture.ia32, null),
  (OS.windows, Architecture.x64, null),
];

/// Formats a canonical target identifier, including [iosSdk] when targeting iOS
/// so device (`iphoneos`) and simulator (`iphonesimulator`) binaries do not
/// collide on `ios-arm64`.
String targetTripleFor(OS os, Architecture arch, {IOSSdk? iosSdk}) {
  if (os == OS.iOS && iosSdk != null) {
    return '${os.name}-${arch.name}-${iosSdk.type}';
  }
  return '${os.name}-${arch.name}';
}

/// Formats the canonical target identifier for [code].
String targetTripleForConfig(CodeConfig code) {
  final targetOS = code.targetOS;
  final iosSdk = targetOS == OS.iOS ? code.iOS.targetSdk : null;
  return targetTripleFor(targetOS, code.targetArchitecture, iosSdk: iosSdk);
}

/// Converts [os], [arch], and optional [iosSdk] into a Rust target triple.
String asRustTarget(OS os, Architecture arch, {IOSSdk? iosSdk}) {
  if (os == OS.iOS &&
      arch == Architecture.arm64 &&
      iosSdk == IOSSdk.iPhoneSimulator) {
    return 'aarch64-apple-ios-sim';
  }
  return switch ((os, arch)) {
    (OS.android, Architecture.arm) => 'armv7-linux-androideabi',
    (OS.android, Architecture.arm64) => 'aarch64-linux-android',
    (OS.android, Architecture.ia32) => 'i686-linux-android',
    (OS.android, Architecture.riscv64) => 'riscv64-linux-android',
    (OS.android, Architecture.x64) => 'x86_64-linux-android',
    (OS.fuchsia, Architecture.arm64) => 'aarch64-unknown-fuchsia',
    (OS.fuchsia, Architecture.x64) => 'x86_64-unknown-fuchsia',
    (OS.iOS, Architecture.arm64) => 'aarch64-apple-ios',
    (OS.iOS, Architecture.x64) => 'x86_64-apple-ios',
    (OS.linux, Architecture.arm) => 'armv7-unknown-linux-gnueabihf',
    (OS.linux, Architecture.arm64) => 'aarch64-unknown-linux-gnu',
    (OS.linux, Architecture.ia32) => 'i686-unknown-linux-gnu',
    (OS.linux, Architecture.riscv32) => 'riscv32gc-unknown-linux-gnu',
    (OS.linux, Architecture.riscv64) => 'riscv64gc-unknown-linux-gnu',
    (OS.linux, Architecture.x64) => 'x86_64-unknown-linux-gnu',
    (OS.macOS, Architecture.arm64) => 'aarch64-apple-darwin',
    (OS.macOS, Architecture.x64) => 'x86_64-apple-darwin',
    (OS.windows, Architecture.arm64) => 'aarch64-pc-windows-msvc',
    (OS.windows, Architecture.ia32) => 'i686-pc-windows-msvc',
    (OS.windows, Architecture.x64) => 'x86_64-pc-windows-msvc',
    (_, _) => throw UnsupportedError(
      'Target ($os, $arch, $iosSdk) is not supported for Rust.',
    ),
  };
}

/// Converts a Dart [CodeConfig] into a Rust target triple.
String asRustTargetForConfig(CodeConfig code) {
  final targetOS = code.targetOS;
  final iosSdk = targetOS == OS.iOS ? code.iOS.targetSdk : null;
  return asRustTarget(targetOS, code.targetArchitecture, iosSdk: iosSdk);
}
