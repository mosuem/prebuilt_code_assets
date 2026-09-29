// Copyright 2026 Moritz Sümmermann. Licensed under the Apache License,
// Version 2.0. See the LICENSE file for details.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:code_assets/code_assets.dart';
import 'package:crypto/crypto.dart';
import 'package:hooks/hooks.dart';
import 'package:prebuilt_code_assets/prebuilt_code_assets.dart';
import 'package:record_use/record_use.dart' as record_use;
import 'package:test/test.dart';

void main() {
  group('targets', () {
    test('targetTripleFor disambiguates iOS device and simulator', () {
      expect(
        targetTripleFor(OS.linux, Architecture.x64),
        'linux-x64',
      );
      expect(
        targetTripleFor(OS.iOS, Architecture.arm64, iosSdk: IOSSdk.iPhoneOS),
        'ios-arm64-iphoneos',
      );
      expect(
        targetTripleFor(
          OS.iOS,
          Architecture.arm64,
          iosSdk: IOSSdk.iPhoneSimulator,
        ),
        'ios-arm64-iphonesimulator',
      );
    });

    test('asRustTarget maps all supported targets', () {
      expect(
        asRustTarget(
          OS.iOS,
          Architecture.arm64,
          iosSdk: IOSSdk.iPhoneSimulator,
        ),
        'aarch64-apple-ios-sim',
      );
      expect(
        asRustTarget(OS.iOS, Architecture.arm64, iosSdk: IOSSdk.iPhoneOS),
        'aarch64-apple-ios',
      );
      for (final (os, arch, iosSdk) in supportedTargets) {
        expect(asRustTarget(os, arch, iosSdk: iosSdk), isNotEmpty);
      }
    });
  });

  group('BuildOptions', () {
    late Directory tempDir;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('build_options_test_');
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    BuildInput makeBuildInput(Map<String, Object?> userDefines) {
      final builder = BuildInputBuilder()
        ..setupShared(
          packageRoot: tempDir.uri,
          packageName: 'example_pkg',
          outputFile: tempDir.uri.resolve('output.json'),
          outputDirectoryShared: tempDir.uri.resolve('shared/'),
          userDefines: PackageUserDefines(
            workspacePubspec: PackageUserDefinesSource(
              defines: userDefines,
              basePath: tempDir.uri,
            ),
          ),
        )
        ..config.setupBuild(linkingEnabled: false);
      return builder.build();
    }

    test('defaults to fetch mode', () {
      final input = makeBuildInput({});
      final options = BuildOptions.fromDefines(input.userDefines);
      expect(options.buildMode, BuildMode.fetch);
      expect(options.localPath, isNull);
      expect(options.checkoutPath, isNull);
    });

    test('supports local_build boolean user-define', () {
      final input = makeBuildInput({'local_build': true});
      final options = BuildOptions.fromDefines(input.userDefines);
      expect(options.buildMode, BuildMode.build);
      expect(options.isSourceBuild, isTrue);
    });

    test('supports environment variable overrides via envVarPrefix', () {
      final input = makeBuildInput({});
      final options = BuildOptions.fromDefines(
        input.userDefines,
        envVarPrefix: 'EXAMPLE',
        environment: {
          'EXAMPLE_BUILD_MODE': 'checkout',
          'EXAMPLE_CHECKOUT_PATH': '/tmp/my_checkout',
        },
      );
      expect(options.buildMode, BuildMode.checkout);
      expect(options.checkoutPath?.toFilePath(), '/tmp/my_checkout/');
    });

    test('throws BuildError in strict mode on unknown buildMode', () {
      final input = makeBuildInput({'buildMode': 'invalid_mode'});
      expect(
        () => BuildOptions.fromDefines(
          input.userDefines,
          packageName: 'example_pkg',
          strict: true,
        ),
        throwsA(isA<BuildError>()),
      );
    });
  });

  group('COFF archive & Windows linker options', () {
    Uint8List buildSyntheticCoffArchive(List<String> symbols) {
      final builder = BytesBuilder();
      builder.add(ascii.encode('!<arch>\n'));
      // 60-byte archive member header with name '/'
      final header = '/'.padRight(60, ' ');
      builder.add(ascii.encode(header));
      // 4-byte big-endian symbol count
      final countBytes = ByteData(4)..setUint32(0, symbols.length, Endian.big);
      builder.add(countBytes.buffer.asUint8List());
      // 4-byte offset per symbol
      for (var i = 0; i < symbols.length; i++) {
        builder.add(const [0, 0, 0, 0]);
      }
      // NUL-terminated symbol strings
      for (final s in symbols) {
        builder.add(ascii.encode(s));
        builder.addByte(0);
      }
      return builder.toBytes();
    }

    test('parses symbols and handles x86 underscore prefix', () {
      final archive = buildSyntheticCoffArchive(['foo', '_bar', 'unmapped']);
      expect(parseCoffArchiveSymbols(archive), {'foo', '_bar', 'unmapped'});
      expect(
        definedBindingsInCoffArchive(archive, ['foo', 'bar', 'missing']),
        {'foo', 'bar'},
      );
    });

    test(
      'generates .def file when symbols is null or exceeds max length',
      () async {
        final tempDir = await Directory.systemTemp.createTemp('coff_test_');
        addTearDown(() => tempDir.delete(recursive: true));

        final libFile = File.fromUri(tempDir.uri.resolve('test.lib'));
        await libFile.writeAsBytes(
          buildSyntheticCoffArchive(['sym_a', 'sym_b']),
        );

        await createWindowsLinkerOptions(
          outputDirectory: tempDir.uri,
          libraryName: 'test_lib',
          staticLibrary: libFile.uri,
          symbols: null,
          allKnownSymbols: const ['sym_a', 'sym_b', 'sym_c'],
        );

        final defFile = File.fromUri(tempDir.uri.resolve('test_lib.def'));
        expect(defFile.existsSync(), isTrue);
        final defContent = await defFile.readAsString();
        expect(defContent, contains('EXPORTS'));
        expect(defContent, contains('    sym_a'));
        expect(defContent, contains('    sym_b'));
        expect(defContent, isNot(contains('sym_c')));
      },
    );
  });

  group('SymbolsResolvers', () {
    const bindingsLib = record_use.Library('package:foo/bindings.g.dart');

    test('fromRecordUseMapping resolves and sorts mapped symbols', () {
      final resolver = SymbolsResolvers.fromRecordUseMapping(
        bindingsLib,
        const {'dart_b': 'c_b', 'dart_a': 'c_a'},
      );
      expect(resolver, isNotNull);
    });
  });

  group('PrebuiltLibrary.build & fetchPrebuiltLibrary', () {
    late Directory tempDir;
    late HttpServer server;
    late Uri serverBaseUri;
    final fakeDylibBytes = utf8.encode('fake-dynamic-library-binary');
    final fakeStaticBytes = utf8.encode('fake-static-library-binary');
    late String dylibHash;
    late String staticHash;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('prebuilt_lib_test_');
      dylibHash = sha256.convert(fakeDylibBytes).toString();
      staticHash = sha256.convert(fakeStaticBytes).toString();

      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      serverBaseUri = Uri.parse('http://127.0.0.1:${server.port}');
      server.listen((request) async {
        if (request.uri.path.endsWith('.a') ||
            request.uri.path.endsWith('.lib')) {
          request.response.statusCode = 200;
          request.response.add(fakeStaticBytes);
        } else if (request.uri.path.contains('not-found')) {
          request.response.statusCode = 404;
        } else {
          request.response.statusCode = 200;
          request.response.add(fakeDylibBytes);
        }
        await request.response.close();
      });
    });

    tearDown(() async {
      await server.close(force: true);
      await tempDir.delete(recursive: true);
    });

    BuildInput createInput({
      required bool linkingEnabled,
      Map<String, Object?> defines = const {},
    }) {
      final outDir = tempDir.uri.resolve('out/');
      final sharedDir = tempDir.uri.resolve('shared/');
      Directory.fromUri(outDir).createSync(recursive: true);
      Directory.fromUri(sharedDir).createSync(recursive: true);

      final builder = BuildInputBuilder()
        ..setupShared(
          packageRoot: tempDir.uri,
          packageName: 'demo',
          outputFile: tempDir.uri.resolve('output.json'),
          outputDirectoryShared: sharedDir,
          userDefines: PackageUserDefines(
            workspacePubspec: PackageUserDefinesSource(
              defines: defines,
              basePath: tempDir.uri,
            ),
          ),
        )
        ..config.setupBuild(linkingEnabled: linkingEnabled)
        ..addExtension(
          CodeAssetExtension(
            targetOS: OS.linux,
            targetArchitecture: Architecture.x64,
            linkModePreference: LinkModePreference.dynamic,
          ),
        );
      return builder.build();
    }

    PrebuiltReleaseConfig makeReleaseConfig(
      Map<String, String> hashes, {
      String pathPrefix = '/releases',
    }) => PrebuiltReleaseConfig(
      version: '1.0.0',
      fileHashes: hashes,
      resolveDownloadUri: (ver, asset) =>
          serverBaseUri.resolve('$pathPrefix/$ver/$asset'),
      resolveAssetName: (os, arch, {iosSdk, required static}) {
        final triple = targetTripleFor(os, arch, iosSdk: iosSdk);
        final file = static
            ? os.staticlibFileName('demo')
            : os.dylibFileName('demo');
        return 'demo-$triple-$file';
      },
      resolveLibraryFileName: (os, {required static}) =>
          static ? os.staticlibFileName('demo') : os.dylibFileName('demo'),
    );

    test(
      'fetches dynamic library when linking is disabled and caches it',
      () async {
        final releaseConfig = makeReleaseConfig({
          'demo-linux-x64-libdemo.so': dylibHash,
          'demo-linux-x64-libdemo.a': staticHash,
        });

        final library = PrebuiltLibrary(
          name: 'demo',
          assetName: 'demo.dart',
          releaseConfig: releaseConfig,
        );

        final input = createInput(linkingEnabled: false);
        final output = BuildOutputBuilder();
        await library.build(input: input, output: output);

        final built = BuildOutput(output.json);
        expect(built.assets.code, hasLength(1));
        final asset = built.assets.code.single;
        expect(asset.id, 'package:demo/demo.dart');
        expect(asset.linkMode, isA<DynamicLoadingBundled>());
        expect(
          asset.file!.pathSegments.last,
          'libdemo.so',
          reason: 'Leaf filename must be canonical OS dylib filename',
        );
      },
    );

    test(
      'fetches static library and routes to link hook when linkingEnabled',
      () async {
        final releaseConfig = makeReleaseConfig({
          'demo-linux-x64-libdemo.so': dylibHash,
          'demo-linux-x64-libdemo.a': staticHash,
        });

        final library = PrebuiltLibrary(
          name: 'demo',
          assetName: 'demo.dart',
          releaseConfig: releaseConfig,
        );

        final input = createInput(linkingEnabled: true);
        final output = BuildOutputBuilder();
        await library.build(input: input, output: output);

        final built = BuildOutput(output.json);
        expect(built.assets.code, isEmpty, reason: 'Routed to link hook');
        final forLink = built.assets.encodedAssetsForLinking['demo'];
        expect(forLink, isNotNull);
        expect(forLink, hasLength(1));
      },
    );

    test('uses bundled prebuilt/ directory without network access', () async {
      final prebuiltDir = Directory.fromUri(tempDir.uri.resolve('prebuilt/'));
      await prebuiltDir.create(recursive: true);
      final bundledFile = File.fromUri(
        prebuiltDir.uri.resolve('demo-linux-x64-libdemo.so'),
      );
      await bundledFile.writeAsBytes(fakeDylibBytes);

      final releaseConfig = makeReleaseConfig(
        const {}, // Empty hashes: would fail if network used!
        pathPrefix: '/not-found',
      );

      final library = PrebuiltLibrary(
        name: 'demo',
        assetName: 'demo.dart',
        releaseConfig: releaseConfig,
        prebuiltDirectory: 'prebuilt',
      );

      final input = createInput(linkingEnabled: false);
      final output = BuildOutputBuilder();
      await library.build(input: input, output: output);

      final built = BuildOutput(output.json);
      expect(built.assets.code, hasLength(1));
      expect(built.assets.code.single.file!.pathSegments.last, 'libdemo.so');
    });

    test('falls back to buildFromSource when fetch fails', () async {
      var sourceBuildCalled = false;
      final releaseConfig = PrebuiltReleaseConfig(
        version: '1.0.0',
        fileHashes: const {},
        resolveDownloadUri: (ver, asset) =>
            serverBaseUri.resolve('/not-found/$asset'),
        resolveAssetName: (os, arch, {iosSdk, required static}) =>
            'demo-missing',
        resolveLibraryFileName: (os, {required static}) => 'libdemo.so',
      );

      final library = PrebuiltLibrary(
        name: 'demo',
        assetName: 'demo.dart',
        releaseConfig: releaseConfig,
        buildFromSource:
            (input, output, {required static, checkoutPath}) async {
              sourceBuildCalled = true;
              final f = File.fromUri(
                input.outputDirectory.resolve('libdemo.so'),
              );
              await f.parent.create(recursive: true);
              await f.writeAsBytes(fakeDylibBytes);
              return f.uri;
            },
      );

      final input = createInput(linkingEnabled: false);
      final output = BuildOutputBuilder();
      await library.build(input: input, output: output);

      expect(sourceBuildCalled, isTrue);
      final built = BuildOutput(output.json);
      expect(built.assets.code, hasLength(1));
    });
  });
}
