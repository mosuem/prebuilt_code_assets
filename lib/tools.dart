// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

/// Maintainer CLI utilities for precompiling release binaries and generating
/// SHA-256 hash manifests.
library;

export 'package:args/command_runner.dart' show UsageException;

export 'src/tools/precompile_binaries.dart';
export 'src/tools/regenerate_hashes.dart';
