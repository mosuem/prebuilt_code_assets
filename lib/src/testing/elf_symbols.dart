// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:io';
import 'dart:typed_data';

/// ELF `e_machine` constant for `aarch64` (`EM_AARCH64`).
const int elfMachineAarch64 = 183;

/// ELF `e_machine` constant for `x86_64` (`EM_X86_64`).
const int elfMachineX86_64 = 62;

/// Returns whether the `aarch64-linux-gnu-gcc` cross-compilation toolchain is
/// available on the host.
bool hasAarch64LinuxToolchain() {
  final which = Platform.isWindows ? 'where' : 'which';
  if (Process.runSync(which, ['aarch64-linux-gnu-gcc']).exitCode == 0) {
    return true;
  }
  return Platform.isMacOS &&
      (File('/opt/homebrew/bin/aarch64-linux-gnu-gcc').existsSync() ||
          File('/usr/local/bin/aarch64-linux-gnu-gcc').existsSync());
}

/// Returns the ELF `e_machine` field of a 64-bit little-endian ELF binary
/// [bytes].
///
/// Throws a [FormatException] if [bytes] is not a valid 64-bit little-endian
/// ELF header.
int elfMachine(Uint8List bytes) {
  const expectedPrefix = [0x7f, 0x45, 0x4c, 0x46, 2, 1];
  if (bytes.length < 64) {
    throw const FormatException('ELF binary is shorter than 64 bytes.');
  }
  for (var i = 0; i < expectedPrefix.length; i++) {
    if (bytes[i] != expectedPrefix[i]) {
      throw const FormatException('Not a 64-bit little-endian ELF binary.');
    }
  }
  return ByteData.sublistView(bytes).getUint16(18, Endian.little);
}

/// Returns the names of all defined symbols in the `.dynsym` section of a
/// 64-bit little-endian ELF binary [bytes].
Set<String> elfDefinedDynamicSymbols(Uint8List bytes) {
  final data = ByteData.sublistView(bytes);
  final shoff = data.getUint64(40, Endian.little);
  final shentsize = data.getUint16(58, Endian.little);
  final shnum = data.getUint16(60, Endian.little);

  const shtDynsym = 11;
  for (var i = 0; i < shnum; i++) {
    final shdr = shoff + i * shentsize;
    final shType = data.getUint32(shdr + 4, Endian.little);
    if (shType != shtDynsym) continue;

    final symOffset = data.getUint64(shdr + 24, Endian.little);
    final symSize = data.getUint64(shdr + 32, Endian.little);
    final strTabIndex = data.getUint32(shdr + 40, Endian.little);
    final symEntSize = data.getUint64(shdr + 56, Endian.little);

    final strShdr = shoff + strTabIndex * shentsize;
    final strOffset = data.getUint64(strShdr + 24, Endian.little);

    final symbols = <String>{};
    final count = symSize ~/ symEntSize;
    for (var j = 0; j < count; j++) {
      final sym = symOffset + j * symEntSize;
      final stName = data.getUint32(sym, Endian.little);
      final stShndx = data.getUint16(sym + 6, Endian.little);
      if (stName == 0 || stShndx == 0) continue;
      final start = strOffset + stName;
      final end = bytes.indexOf(0, start);
      symbols.add(String.fromCharCodes(bytes, start, end));
    }
    return symbols;
  }
  throw StateError('No .dynsym section found in ELF binary.');
}
