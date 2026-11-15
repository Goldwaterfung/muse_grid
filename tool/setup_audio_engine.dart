import 'dart:convert';
import 'dart:io';

/// Cross-platform bootstrap script for MuseGrid's C/C++ and Emscripten
/// audio engine dependencies (`FluidSynth`, `miniaudio`, `PicoSHA2`, `Catch2`,
/// and `emsdk`).
///
/// Run from the repository root on macOS, Linux, or Windows:
///   dart tool/setup_audio_engine.dart
abstract final class _SetupConstants {
  static const String pinnedEmsdkVersion = '7.0.0';
  static const String emsdkRepoUrl =
      'https://github.com/emscripten-core/emsdk.git';

  static const int minCmakeMajor = 3;
  static const int minCmakeMinor = 24;

  static const String audioEngineRelativeDir = 'packages/muse_audio_engine';
  static const String defaultEmsdkRelativeDir =
      'packages/muse_audio_engine/.emsdk';
  static const String nativeBuildRelativeDir =
      'packages/muse_audio_engine/.build';
  static const String wasmBuildRelativeDir =
      'packages/muse_audio_engine/.build_wasm';

  /// Minimum macOS deployment target matching Flutter's `MacOSAssetTarget`
  /// (`targetMacOSVersion = 13` in `flutter_tools` / `code_assets`), preventing
  /// `ld` version-mismatch warnings when linking static archives.
  static const String macosDeploymentTarget = '13.0';

  /// Minimum iOS deployment target matching `IPHONEOS_DEPLOYMENT_TARGET` in
  /// `ios/Runner.xcodeproj/project.pbxproj` and Flutter's `targetIOSVersion`.
  static const String iosDeploymentTarget = '15.0';

  /// Default Android API level matching `minSdk = 30` in
  /// `android/app/build.gradle.kts`.
  static const int defaultAndroidApiLevel = 30;

  /// Minimum supported Android API level in MuseGrid.
  static const int minSupportedAndroidApiLevel = 24;

  /// Android C++ STL matching `cppLinkStdLib: 'c++_static'` in `hook/build.dart`.
  static const String androidStl = 'c++_static';

  /// macOS architectures built for universal `flutter build macos` binaries
  /// (`hook/build.dart` resolves `.build_macos_<hookArch>/`).
  static const List<({String hookArch, String cmakeArch})> macosTargetArchs = [
    (hookArch: 'arm64', cmakeArch: 'arm64'),
    (hookArch: 'x64', cmakeArch: 'x86_64'),
  ];

  /// Android ABIs built for `flutter build apk` / `flutter build appbundle`
  /// (`hook/build.dart` resolves `.build_android_<hookArch>/`).
  static const List<({String hookArch, String androidAbi})> androidTargets = [
    (hookArch: 'arm64', androidAbi: 'arm64-v8a'),
    (hookArch: 'arm', androidAbi: 'armeabi-v7a'),
    (hookArch: 'x64', androidAbi: 'x86_64'),
  ];

  /// iOS SDK + architecture slices built for device & simulator builds
  /// (`hook/build.dart` resolves `.build_ios_<sdk>_<hookArch>/`).
  static const List<({String sdk, String hookArch, String cmakeArch})>
  iosTargets = [
    (sdk: 'iphoneos', hookArch: 'arm64', cmakeArch: 'arm64'),
    (sdk: 'iphonesimulator', hookArch: 'arm64', cmakeArch: 'arm64'),
    (sdk: 'iphonesimulator', hookArch: 'x64', cmakeArch: 'x86_64'),
  ];

  static const String nativeEngineTarget = 'muse_audio_engine_core';
  static const String buildConfig = 'Release';
  static const String wasmEngineTarget = 'muse_audio_engine';
  static const String webOutputRelativeDir = 'web';
  static const List<String> wasmWebArtifactNames = <String>[
    'muse_audio_engine.js',
    'muse_audio_engine.wasm',
  ];
  static const String ctestFilterRegex = r'^muse\.';
}

final class _SetupOptions {
  final String? emsdkDirOverride;
  final String? cmakeGeneratorOverride;
  final String? androidNdkOverride;
  final List<String>? androidAbisOverride;
  final int androidApiLevel;
  final bool buildAndroid;
  final bool buildIos;
  final bool skipNative;
  final bool skipWasm;
  final bool showHelp;

  const _SetupOptions({
    required this.emsdkDirOverride,
    required this.cmakeGeneratorOverride,
    required this.androidNdkOverride,
    required this.androidAbisOverride,
    required this.androidApiLevel,
    required this.buildAndroid,
    required this.buildIos,
    required this.skipNative,
    required this.skipWasm,
    required this.showHelp,
  });

  static _SetupOptions parse(List<String> args) {
    String? emsdkDirOverride;
    String? cmakeGeneratorOverride;
    String? androidNdkOverride;
    List<String>? androidAbisOverride;
    var androidApiLevel = _SetupConstants.defaultAndroidApiLevel;
    var buildAndroid = false;
    var buildIos = false;
    var skipNative = false;
    var skipWasm = false;
    var showHelp = false;

    for (final arg in args) {
      if (arg == '--help' || arg == '-h') {
        showHelp = true;
      } else if (arg == '--skip-native') {
        skipNative = true;
      } else if (arg == '--skip-wasm') {
        skipWasm = true;
      } else if (arg == '--android') {
        buildAndroid = true;
      } else if (arg == '--ios') {
        buildIos = true;
      } else if (arg.startsWith('--emsdk-dir=')) {
        emsdkDirOverride = arg.substring('--emsdk-dir='.length).trim();
      } else if (arg.startsWith('--generator=')) {
        cmakeGeneratorOverride = arg.substring('--generator='.length).trim();
      } else if (arg.startsWith('--android-ndk=')) {
        androidNdkOverride = arg.substring('--android-ndk='.length).trim();
        buildAndroid = true;
      } else if (arg.startsWith('--android-abis=')) {
        final raw = arg.substring('--android-abis='.length).trim();
        if (raw.isEmpty) {
          throw const FormatException('--android-abis= requires a non-empty list.');
        }
        androidAbisOverride = raw
            .split(',')
            .map((e) => e.trim())
            .where((e) => e.isNotEmpty)
            .toList();
        buildAndroid = true;
      } else if (arg.startsWith('--android-api=')) {
        final raw = arg.substring('--android-api='.length).trim();
        final parsed = int.tryParse(raw);
        if (parsed == null ||
            parsed < _SetupConstants.minSupportedAndroidApiLevel) {
          throw FormatException(
            'Invalid --android-api value "$raw" '
            '(expected integer >= ${_SetupConstants.minSupportedAndroidApiLevel}).',
          );
        }
        androidApiLevel = parsed;
        buildAndroid = true;
      } else {
        throw FormatException('Unknown option: $arg');
      }
    }

    return _SetupOptions(
      emsdkDirOverride: emsdkDirOverride,
      cmakeGeneratorOverride: cmakeGeneratorOverride,
      androidNdkOverride: androidNdkOverride,
      androidAbisOverride: androidAbisOverride,
      androidApiLevel: androidApiLevel,
      buildAndroid: buildAndroid,
      buildIos: buildIos,
      skipNative: skipNative,
      skipWasm: skipWasm,
      showHelp: showHelp,
    );
  }
}

Future<void> main(List<String> args) async {
  final _SetupOptions options;
  try {
    options = _SetupOptions.parse(args);
  } on FormatException catch (e) {
    stderr.writeln('Error: ${e.message}');
    _printUsage();
    exitCode = 2;
    return;
  }

  if (options.showHelp) {
    _printUsage();
    return;
  }

  final repoRoot = _resolveRepoRoot();
  if (repoRoot == null) {
    stderr.writeln(
      'Error: Could not locate pubspec.yaml and '
      '${_SetupConstants.audioEngineRelativeDir}/CMakeLists.txt. '
      'Run from inside the muse_grid repository.',
    );
    exitCode = 1;
    return;
  }

  try {
    await _verifyCoreHostTools(requireWasmTools: !options.skipWasm);

    String? androidNdkRoot;
    if (options.buildAndroid) {
      androidNdkRoot = _resolveAndroidNdkDir(
        repoRoot,
        options.androidNdkOverride,
      );
      stdout.writeln('  Using Android NDK: $androidNdkRoot');
    }

    if (options.buildIos) {
      await _verifyIosTools();
    }

    String? emsdkRoot;
    if (!options.skipWasm) {
      emsdkRoot = await _ensureEmsdk(repoRoot, options.emsdkDirOverride);
    }

    if (!options.skipNative) {
      await _setupNativeDeps(repoRoot, options.cmakeGeneratorOverride);
    }

    if (options.buildAndroid && androidNdkRoot != null) {
      await _setupAndroidDeps(
        repoRoot: repoRoot,
        ndkRoot: androidNdkRoot,
        apiLevel: options.androidApiLevel,
        abisOverride: options.androidAbisOverride,
        generatorOverride: options.cmakeGeneratorOverride,
      );
    }

    if (options.buildIos) {
      await _setupIosDeps(
        repoRoot: repoRoot,
        generatorOverride: options.cmakeGeneratorOverride,
      );
    }

    if (!options.skipWasm && emsdkRoot != null) {
      await _setupWasmDeps(
        repoRoot,
        emsdkRoot,
        options.cmakeGeneratorOverride,
      );
    }

    stdout.writeln('');
    stdout.writeln('Audio engine dependency setup completed successfully.');
  } on _SetupException catch (e) {
    stderr.writeln('');
    stderr.writeln('Setup failed: ${e.message}');
    exitCode = 1;
  }
}

void _printUsage() {
  stdout.writeln(
    '''
Usage: dart tool/setup_audio_engine.dart [options]

Installs Emscripten SDK (${_SetupConstants.pinnedEmsdkVersion}) and fetches/builds all pinned C/C++
audio engine dependencies (FluidSynth, miniaudio, PicoSHA2, Catch2) via CMake.

Options:
  --emsdk-dir=<path>     Install/use emsdk at a custom directory
                         (default: \$EMSDK or ${_SetupConstants.defaultEmsdkRelativeDir})
  --generator=<name>     Override the CMake generator (e.g. "Unix Makefiles", "Ninja")
  --android              Cross-compile static archives for Android NDK ABIs
                         (${_SetupConstants.androidTargets.map((t) => t.androidAbi).join(', ')})
  --android-abis=<list>  Comma-separated Android ABIs or hook arches to build
                         (e.g. "arm64-v8a,x86_64" or "arm64,x64"; implies --android)
  --android-ndk=<path>   Override Android NDK path (default: ANDROID_NDK_HOME/ROOT
                         or newest NDK under Android SDK)
  --android-api=<level>  Android API level for -DANDROID_PLATFORM
                         (default: ${_SetupConstants.defaultAndroidApiLevel}; implies --android)
  --ios                  (macOS only) Cross-compile static archives for iOS
                         (iphoneos arm64, iphonesimulator arm64 & x86_64)
  --skip-native          Skip host Native C++ FetchContent + test verification
  --skip-wasm            Skip Emscripten SDK setup and Wasm engine core build
  -h, --help             Show this help text
''',
  );
}

Directory? _resolveRepoRoot() {
  var current = Directory.current.absolute;
  while (true) {
    final pubspec = File(_joinPath(current.path, 'pubspec.yaml'));
    final engineCmake = File(
      _joinPath(
        current.path,
        '${_SetupConstants.audioEngineRelativeDir}/CMakeLists.txt',
      ),
    );
    if (pubspec.existsSync() && engineCmake.existsSync()) {
      return current;
    }
    final parent = current.parent;
    if (parent.path == current.path) {
      return null;
    }
    current = parent;
  }
}

Future<void> _verifyCoreHostTools({required bool requireWasmTools}) async {
  stdout.writeln('==> Checking host tools...');
  await _requireCommand('git', ['--version']);

  final cmakeOutput = await _requireCommand('cmake', ['--version']);
  _verifyCmakeVersion(cmakeOutput);

  if (!Platform.isWindows) {
    await _requireCommand('make', ['--version']);
    if (requireWasmTools) {
      await _requireCommand('python3', ['--version']);
    }
  }
}

Future<String> _requireCommand(String executable, List<String> args) async {
  try {
    final result = await Process.run(
      executable,
      args,
      runInShell: Platform.isWindows,
    );
    if (result.exitCode != 0) {
      throw _SetupException(
        '"$executable ${args.join(' ')}" exited with code ${result.exitCode}.\n'
        '${result.stderr}',
      );
    }
    return '${result.stdout}\n${result.stderr}'.trim();
  } on ProcessException catch (e) {
    throw _SetupException(
      'Required tool "$executable" was not found on PATH (${e.message}).',
    );
  }
}

void _verifyCmakeVersion(String versionOutput) {
  final match = RegExp(r'cmake version (\d+)\.(\d+)').firstMatch(versionOutput);
  if (match == null) {
    throw _SetupException('Unable to parse CMake version from:\n$versionOutput');
  }
  final major = int.parse(match.group(1)!);
  final minor = int.parse(match.group(2)!);
  final meetsMinimum =
      major > _SetupConstants.minCmakeMajor ||
      (major == _SetupConstants.minCmakeMajor &&
          minor >= _SetupConstants.minCmakeMinor);
  if (!meetsMinimum) {
    throw _SetupException(
      'CMake >= ${_SetupConstants.minCmakeMajor}.${_SetupConstants.minCmakeMinor} '
      'is required, found $major.$minor.',
    );
  }
}

Future<String> _ensureEmsdk(Directory repoRoot, String? overrideDir) async {
  stdout.writeln('');
  stdout.writeln(
    '==> Setting up Emscripten SDK (${_SetupConstants.pinnedEmsdkVersion})...',
  );

  final envEmsdk = Platform.environment['EMSDK']?.trim();
  final emsdkPath = (overrideDir != null && overrideDir.isNotEmpty)
      ? _resolveAbsolutePath(repoRoot.path, overrideDir)
      : (envEmsdk != null && envEmsdk.isNotEmpty)
      ? envEmsdk
      : _joinPath(repoRoot.path, _SetupConstants.defaultEmsdkRelativeDir);

  final emsdkDir = Directory(emsdkPath);
  if (!emsdkDir.existsSync()) {
    emsdkDir.parent.createSync(recursive: true);
    await _runStreaming(
      'git',
      ['clone', _SetupConstants.emsdkRepoUrl, emsdkDir.path],
      workingDirectory: repoRoot.path,
    );
  }

  final emsdkExe = Platform.isWindows
      ? _joinPath(emsdkDir.path, 'emsdk.bat')
      : _joinPath(emsdkDir.path, 'emsdk');

  if (!File(emsdkExe).existsSync()) {
    throw _SetupException(
      'Expected emsdk entrypoint not found at $emsdkExe. '
      'Remove or fix the directory and re-run.',
    );
  }

  await _runEmsdkCommand(emsdkExe, [
    'install',
    _SetupConstants.pinnedEmsdkVersion,
  ], workingDirectory: emsdkDir.path);
  await _runEmsdkCommand(emsdkExe, [
    'activate',
    _SetupConstants.pinnedEmsdkVersion,
  ], workingDirectory: emsdkDir.path);

  final emsdkEnv = _buildEmsdkEnvironment(emsdkDir.path);
  final emccPath = _emccExecutablePath(emsdkDir.path);
  if (!File(emccPath).existsSync()) {
    throw _SetupException(
      'Emscripten activation succeeded, but emcc was not found at $emccPath.',
    );
  }

  await _runStreaming(
    emccPath,
    ['--version'],
    workingDirectory: emsdkDir.path,
    environment: emsdkEnv,
  );

  return emsdkDir.path;
}

Future<void> _runEmsdkCommand(
  String emsdkExe,
  List<String> args, {
  required String workingDirectory,
}) async {
  if (Platform.isWindows) {
    await _runStreaming(
      'cmd.exe',
      ['/c', emsdkExe, ...args],
      workingDirectory: workingDirectory,
    );
  } else {
    await _runStreaming(
      emsdkExe,
      args,
      workingDirectory: workingDirectory,
    );
  }
}

Map<String, String> _buildEmsdkEnvironment(String emsdkRoot) {
  final env = Map<String, String>.from(Platform.environment);
  final upstreamEmscripten = _joinPath(emsdkRoot, 'upstream/emscripten');
  final upstreamBin = _joinPath(emsdkRoot, 'upstream/bin');
  final pathEntries = <String>[emsdkRoot, upstreamEmscripten, upstreamBin];

  final nodeRoot = Directory(_joinPath(emsdkRoot, 'node'));
  if (nodeRoot.existsSync()) {
    for (final entity in nodeRoot.listSync().whereType<Directory>()) {
      final binDir = Directory(_joinPath(entity.path, 'bin'));
      if (binDir.existsSync()) {
        pathEntries.add(binDir.path);
      } else {
        pathEntries.add(entity.path);
      }
    }
  }

  final pythonRoot = Directory(_joinPath(emsdkRoot, 'python'));
  if (pythonRoot.existsSync()) {
    for (final entity in pythonRoot.listSync().whereType<Directory>()) {
      final binDir = Directory(_joinPath(entity.path, 'bin'));
      if (binDir.existsSync()) {
        pathEntries.add(binDir.path);
      } else {
        pathEntries.add(entity.path);
      }
    }
  }

  final separator = Platform.isWindows ? ';' : ':';
  final existingPath = env['PATH'] ?? '';
  env['EMSDK'] = emsdkRoot;
  env['EM_CONFIG'] = _joinPath(emsdkRoot, '.emscripten');
  env['PATH'] = '${pathEntries.join(separator)}$separator$existingPath';
  return env;
}

Future<void> _setupNativeDeps(
  Directory repoRoot,
  String? generatorOverride,
) async {
  stdout.writeln('');
  stdout.writeln('==> Fetching & verifying Native C/C++ dependencies...');

  final sourceDir = _joinPath(
    repoRoot.path,
    _SetupConstants.audioEngineRelativeDir,
  );
  final buildDir = _joinPath(
    repoRoot.path,
    _SetupConstants.nativeBuildRelativeDir,
  );
  final generator =
      generatorOverride ?? (Platform.isWindows ? null : 'Unix Makefiles');

  final hostExpectedCache = <String, String>{
    if (Platform.isMacOS)
      'CMAKE_OSX_DEPLOYMENT_TARGET': _SetupConstants.macosDeploymentTarget,
  };
  await _configureAndBuildNativeDir(
    repoRoot: repoRoot,
    sourceDir: sourceDir,
    buildDir: buildDir,
    generator: generator,
    expectedCacheEntries: hostExpectedCache,
  );

  await _runStreaming(
    'ctest',
    [
      '--test-dir',
      buildDir,
      '--build-config',
      _SetupConstants.buildConfig,
      '--output-on-failure',
      '-R',
      _SetupConstants.ctestFilterRegex,
    ],
    workingDirectory: repoRoot.path,
  );

  if (Platform.isMacOS) {
    final sharedSourceArgs = _localFetchContentSourceArgs(buildDir);
    for (final target in _SetupConstants.macosTargetArchs) {
      stdout.writeln('');
      stdout.writeln(
        '==> Building macOS ${target.hookArch} (${target.cmakeArch}) '
        'static archives...',
      );
      final archBuildDir = _joinPath(
        repoRoot.path,
        '${_SetupConstants.nativeBuildRelativeDir}_macos_${target.hookArch}',
      );
      await _configureAndBuildNativeDir(
        repoRoot: repoRoot,
        sourceDir: sourceDir,
        buildDir: archBuildDir,
        generator: generator,
        expectedCacheEntries: {
          'CMAKE_OSX_ARCHITECTURES': target.cmakeArch,
          'CMAKE_OSX_DEPLOYMENT_TARGET': _SetupConstants.macosDeploymentTarget,
        },
        extraCmakeArgs: ['-DBUILD_TESTING=OFF', ...sharedSourceArgs],
        target: _SetupConstants.nativeEngineTarget,
      );
    }
  }
}

String _resolveAndroidNdkDir(Directory repoRoot, String? overridePath) {
  String toolchainPathFor(String ndkDir) =>
      _joinPath(ndkDir, 'build/cmake/android.toolchain.cmake');

  if (overridePath != null && overridePath.isNotEmpty) {
    final resolved = _resolveAbsolutePath(repoRoot.path, overridePath);
    if (!File(toolchainPathFor(resolved)).existsSync()) {
      throw _SetupException(
        'Specified Android NDK is invalid (missing build/cmake/android.toolchain.cmake): '
        '$resolved',
      );
    }
    return resolved;
  }

  for (final envVar in const [
    'ANDROID_NDK_HOME',
    'ANDROID_NDK_ROOT',
    'ANDROID_NDK',
  ]) {
    final envValue = Platform.environment[envVar]?.trim();
    if (envValue != null && envValue.isNotEmpty) {
      if (!File(toolchainPathFor(envValue)).existsSync()) {
        throw _SetupException(
          'Environment variable $envVar points to an invalid NDK directory '
          '(missing build/cmake/android.toolchain.cmake): $envValue',
        );
      }
      return envValue;
    }
  }

  final sdkCandidates = _candidateAndroidSdkDirs();
  for (final sdkDir in sdkCandidates) {
    final ndkParent = Directory(_joinPath(sdkDir, 'ndk'));
    if (!ndkParent.existsSync()) {
      continue;
    }
    final validVersions = <(List<int> parts, String path)>[];
    for (final entry in ndkParent.listSync().whereType<Directory>()) {
      final name = entry.path.split(RegExp(r'[/\\]')).last;
      final parsedParts = _parseVersionParts(name);
      if (parsedParts != null && File(toolchainPathFor(entry.path)).existsSync()) {
        validVersions.add((parsedParts, entry.path));
      }
    }
    if (validVersions.isNotEmpty) {
      validVersions.sort((a, b) => _compareVersionParts(b.$1, a.$1));
      return validVersions.first.$2;
    }
  }

  throw _SetupException(
    'Android NDK was not found. Checked ANDROID_NDK_HOME, ANDROID_NDK_ROOT, '
    'ANDROID_NDK, and <AndroidSDK>/ndk/* inside '
    '${sdkCandidates.isEmpty ? '(no Android SDK directories found)' : sdkCandidates.join(', ')}.\n'
    'Install "NDK (Side by side)" in Android Studio -> SDK Manager -> SDK Tools, '
    'or pass --android-ndk=<path>.',
  );
}

List<String> _candidateAndroidSdkDirs() {
  final candidates = <String>[];
  for (final envVar in const ['ANDROID_HOME', 'ANDROID_SDK_ROOT']) {
    final value = Platform.environment[envVar]?.trim();
    if (value != null && value.isNotEmpty && !candidates.contains(value)) {
      candidates.add(value);
    }
  }
  final home = Platform.environment['HOME']?.trim();
  if (Platform.isMacOS && home != null && home.isNotEmpty) {
    final macDefault = _joinPath(home, 'Library/Android/sdk');
    if (!candidates.contains(macDefault)) {
      candidates.add(macDefault);
    }
  } else if (Platform.isLinux && home != null && home.isNotEmpty) {
    final linuxDefault = _joinPath(home, 'Android/Sdk');
    if (!candidates.contains(linuxDefault)) {
      candidates.add(linuxDefault);
    }
  } else if (Platform.isWindows) {
    final localAppData = Platform.environment['LOCALAPPDATA']?.trim();
    if (localAppData != null && localAppData.isNotEmpty) {
      final winDefault = _joinPath(localAppData, 'Android/Sdk');
      if (!candidates.contains(winDefault)) {
        candidates.add(winDefault);
      }
    }
  }
  return candidates;
}

List<int>? _parseVersionParts(String raw) {
  final segments = raw.split('.');
  if (segments.isEmpty) {
    return null;
  }
  final parts = <int>[];
  for (final segment in segments) {
    final value = int.tryParse(segment);
    if (value == null) {
      return null;
    }
    parts.add(value);
  }
  return parts;
}

int _compareVersionParts(List<int> a, List<int> b) {
  final maxLen = a.length > b.length ? a.length : b.length;
  for (var i = 0; i < maxLen; i++) {
    final av = i < a.length ? a[i] : 0;
    final bv = i < b.length ? b[i] : 0;
    if (av != bv) {
      return av.compareTo(bv);
    }
  }
  return 0;
}

Future<void> _verifyIosTools() async {
  if (!Platform.isMacOS) {
    throw const _SetupException(
      'iOS CMake cross-compilation (--ios) is only supported on macOS with Xcode installed.',
    );
  }
  stdout.writeln('==> Checking Xcode iOS SDKs...');
  for (final sdk in const ['iphoneos', 'iphonesimulator']) {
    await _requireCommand('xcrun', ['--sdk', sdk, '--show-sdk-path']);
  }
}

Future<void> _setupAndroidDeps({
  required Directory repoRoot,
  required String ndkRoot,
  required int apiLevel,
  required List<String>? abisOverride,
  required String? generatorOverride,
}) async {
  final targets = _filterAndroidTargets(abisOverride);
  final sourceDir = _joinPath(
    repoRoot.path,
    _SetupConstants.audioEngineRelativeDir,
  );
  final hostBuildDir = _joinPath(
    repoRoot.path,
    _SetupConstants.nativeBuildRelativeDir,
  );
  final sharedSourceArgs = _localFetchContentSourceArgs(hostBuildDir);
  final toolchainFile = _joinPath(
    ndkRoot,
    'build/cmake/android.toolchain.cmake',
  );
  final generator =
      generatorOverride ?? await _resolveAndroidCmakeGenerator(ndkRoot);

  for (final target in targets) {
    stdout.writeln('');
    stdout.writeln(
      '==> Building Android ${target.androidAbi} (${target.hookArch}, '
      'android-$apiLevel) static archives...',
    );
    final abiBuildDir = _joinPath(
      repoRoot.path,
      '${_SetupConstants.nativeBuildRelativeDir}_android_${target.hookArch}',
    );
    await _configureAndBuildNativeDir(
      repoRoot: repoRoot,
      sourceDir: sourceDir,
      buildDir: abiBuildDir,
      generator: generator,
      expectedCacheEntries: {
        'CMAKE_TOOLCHAIN_FILE': toolchainFile,
        'ANDROID_ABI': target.androidAbi,
        'ANDROID_PLATFORM': 'android-$apiLevel',
        'ANDROID_STL': _SetupConstants.androidStl,
      },
      extraCmakeArgs: ['-DBUILD_TESTING=OFF', ...sharedSourceArgs],
      target: _SetupConstants.nativeEngineTarget,
    );
  }
}

List<({String hookArch, String androidAbi})> _filterAndroidTargets(
  List<String>? abisOverride,
) {
  if (abisOverride == null || abisOverride.isEmpty) {
    return _SetupConstants.androidTargets;
  }
  final selected = <({String hookArch, String androidAbi})>[];
  for (final token in abisOverride) {
    final match = _SetupConstants.androidTargets.where(
      (t) => t.androidAbi == token || t.hookArch == token,
    );
    if (match.isEmpty) {
      throw _SetupException(
        'Unsupported Android ABI "$token". Supported values: '
        '${_SetupConstants.androidTargets.map((t) => '${t.androidAbi} (${t.hookArch})').join(', ')}.',
      );
    }
    final target = match.first;
    if (!selected.contains(target)) {
      selected.add(target);
    }
  }
  return selected;
}

Future<String> _resolveAndroidCmakeGenerator(String ndkRoot) async {
  if (!Platform.isWindows) {
    return 'Unix Makefiles';
  }
  for (final candidate in const [
    ('ninja', 'Ninja'),
    ('mingw32-make', 'MinGW Makefiles'),
    ('make', 'Unix Makefiles'),
  ]) {
    if (await _canExecute(candidate.$1, ['--version'])) {
      return candidate.$2;
    }
  }
  final sdkRoot = Directory(ndkRoot).parent.parent;
  final cmakeRoot = Directory(_joinPath(sdkRoot.path, 'cmake'));
  if (cmakeRoot.existsSync()) {
    for (final versionDir in cmakeRoot.listSync().whereType<Directory>()) {
      final ninjaExe = File(_joinPath(versionDir.path, 'bin/ninja.exe'));
      if (ninjaExe.existsSync()) {
        return 'Ninja';
      }
    }
  }
  throw const _SetupException(
    'No CMake generator found on Windows for Android NDK cross-compilation. '
    'Install Ninja or Android SDK CMake (or pass --generator=<name>).',
  );
}

Future<void> _setupIosDeps({
  required Directory repoRoot,
  required String? generatorOverride,
}) async {
  final sourceDir = _joinPath(
    repoRoot.path,
    _SetupConstants.audioEngineRelativeDir,
  );
  final hostBuildDir = _joinPath(
    repoRoot.path,
    _SetupConstants.nativeBuildRelativeDir,
  );
  final sharedSourceArgs = _localFetchContentSourceArgs(hostBuildDir);
  final generator = generatorOverride ?? 'Unix Makefiles';

  for (final target in _SetupConstants.iosTargets) {
    stdout.writeln('');
    stdout.writeln(
      '==> Building iOS ${target.sdk}/${target.hookArch} (${target.cmakeArch}) '
      'static archives...',
    );
    final iosBuildDir = _joinPath(
      repoRoot.path,
      '${_SetupConstants.nativeBuildRelativeDir}_ios_${target.sdk}_${target.hookArch}',
    );
    await _configureAndBuildNativeDir(
      repoRoot: repoRoot,
      sourceDir: sourceDir,
      buildDir: iosBuildDir,
      generator: generator,
      expectedCacheEntries: {
        'CMAKE_SYSTEM_NAME': 'iOS',
        'CMAKE_OSX_SYSROOT': target.sdk,
        'CMAKE_OSX_ARCHITECTURES': target.cmakeArch,
        'CMAKE_OSX_DEPLOYMENT_TARGET': _SetupConstants.iosDeploymentTarget,
      },
      extraCmakeArgs: ['-DBUILD_TESTING=OFF', ...sharedSourceArgs],
      target: _SetupConstants.nativeEngineTarget,
    );
  }
}

/// Configures and builds a native CMake directory, forcing a clean rebuild when
/// cached Apple deployment-target or architecture settings have changed.
Future<void> _configureAndBuildNativeDir({
  required Directory repoRoot,
  required String sourceDir,
  required String buildDir,
  required String? generator,
  Map<String, String> expectedCacheEntries = const {},
  List<String> extraCmakeArgs = const [],
  String? target,
}) async {
  final needsCleanRebuild = _cmakeCacheMismatches(
    buildDir,
    expectedCacheEntries,
  );

  final configureArgs = <String>[
    if (needsCleanRebuild) '--fresh',
    '-S',
    sourceDir,
    '-B',
    buildDir,
    if (generator != null) ...['-G', generator],
    if (!Platform.isWindows) '-DCMAKE_BUILD_TYPE=${_SetupConstants.buildConfig}',
    for (final entry in expectedCacheEntries.entries)
      '-D${entry.key}=${entry.value}',
    ...extraCmakeArgs,
  ];
  await _runStreaming('cmake', configureArgs, workingDirectory: repoRoot.path);

  final buildArgs = <String>[
    '--build',
    buildDir,
    '--config',
    _SetupConstants.buildConfig,
    if (needsCleanRebuild) '--clean-first',
    if (target != null) ...['--target', target],
    '--parallel',
  ];
  await _runStreaming('cmake', buildArgs, workingDirectory: repoRoot.path);
}

bool _cmakeCacheMismatches(
  String buildDir,
  Map<String, String> expectedEntries,
) {
  if (expectedEntries.isEmpty) {
    return false;
  }
  final cacheFile = File(_joinPath(buildDir, 'CMakeCache.txt'));
  if (!cacheFile.existsSync()) {
    return false;
  }

  final cachedValues = <String, String>{};
  for (final line in cacheFile.readAsLinesSync()) {
    final trimmed = line.trim();
    if (trimmed.isEmpty ||
        trimmed.startsWith('#') ||
        trimmed.startsWith('//')) {
      continue;
    }
    final eqIndex = trimmed.indexOf('=');
    if (eqIndex <= 0) {
      continue;
    }
    final keyAndType = trimmed.substring(0, eqIndex);
    final colonIndex = keyAndType.indexOf(':');
    final key = colonIndex > 0
        ? keyAndType.substring(0, colonIndex)
        : keyAndType;
    cachedValues[key] = trimmed.substring(eqIndex + 1);
  }

  for (final entry in expectedEntries.entries) {
    if (cachedValues[entry.key] != entry.value) {
      return true;
    }
  }
  return false;
}

List<String> _localFetchContentSourceArgs(String hostBuildDir) {
  const deps = <(String cmakeVar, String dirName)>[
    ('FETCHCONTENT_SOURCE_DIR_FLUIDSYNTH', 'fluidsynth-src'),
    ('FETCHCONTENT_SOURCE_DIR_MINIAUDIO', 'miniaudio-src'),
    ('FETCHCONTENT_SOURCE_DIR_PICOSHA2', 'picosha2-src'),
  ];
  final args = <String>[];
  for (final (cmakeVar, dirName) in deps) {
    final srcDir = Directory(_joinPath(hostBuildDir, '_deps/$dirName'));
    if (srcDir.existsSync()) {
      args.add('-D$cmakeVar=${srcDir.path}');
    }
  }
  return args;
}

Future<void> _setupWasmDeps(
  Directory repoRoot,
  String emsdkRoot,
  String? generatorOverride,
) async {
  stdout.writeln('');
  stdout.writeln(
    '==> Fetching & building WebAssembly ${_SetupConstants.wasmEngineTarget}...',
  );

  final sourceDir = _joinPath(
    repoRoot.path,
    _SetupConstants.audioEngineRelativeDir,
  );
  final buildDir = _joinPath(
    repoRoot.path,
    _SetupConstants.wasmBuildRelativeDir,
  );
  final toolchainFile = _joinPath(
    emsdkRoot,
    'upstream/emscripten/cmake/Modules/Platform/Emscripten.cmake',
  );
  if (!File(toolchainFile).existsSync()) {
    throw _SetupException(
      'Emscripten CMake toolchain file not found at $toolchainFile.',
    );
  }

  final emsdkEnv = _buildEmsdkEnvironment(emsdkRoot);
  final generator =
      generatorOverride ?? await _resolveWasmCmakeGenerator(emsdkEnv);

  await _runStreaming(
    'cmake',
    [
      '-S',
      sourceDir,
      '-B',
      buildDir,
      '-G',
      generator,
      '-DCMAKE_TOOLCHAIN_FILE=$toolchainFile',
      '-DCMAKE_BUILD_TYPE=${_SetupConstants.buildConfig}',
    ],
    workingDirectory: repoRoot.path,
    environment: emsdkEnv,
  );

  await _runStreaming(
    'cmake',
    [
      '--build',
      buildDir,
      '--target',
      _SetupConstants.wasmEngineTarget,
      '--parallel',
    ],
    workingDirectory: repoRoot.path,
    environment: emsdkEnv,
  );

  final webDir = Directory(
    _joinPath(repoRoot.path, _SetupConstants.webOutputRelativeDir),
  );
  if (!webDir.existsSync()) {
    webDir.createSync(recursive: true);
  }
  for (final artifactName in _SetupConstants.wasmWebArtifactNames) {
    final srcFile = File(_joinPath(buildDir, artifactName));
    if (!srcFile.existsSync()) {
      throw _SetupException(
        'Expected Emscripten build artifact missing at ${srcFile.path}.',
      );
    }
    final dstPath = _joinPath(webDir.path, artifactName);
    srcFile.copySync(dstPath);
    stdout.writeln('  Deployed $dstPath');
  }
}

Future<String> _resolveWasmCmakeGenerator(Map<String, String> env) async {
  if (!Platform.isWindows) {
    return 'Unix Makefiles';
  }

  final candidates = <(String cmd, String generator)>[
    ('mingw32-make', 'MinGW Makefiles'),
    ('make', 'Unix Makefiles'),
    ('nmake', 'NMake Makefiles'),
    ('ninja', 'Ninja'),
  ];

  for (final (cmd, generator) in candidates) {
    if (await _canExecute(cmd, ['--version'], env: env) ||
        await _canExecute(cmd, ['/?'], env: env)) {
      return generator;
    }
  }

  throw _SetupException(
    'No CMake build tool found on Windows for Emscripten '
    '(tried mingw32-make, make, nmake, ninja). '
    'Run from a Visual Studio Developer Prompt (for nmake) or install make/mingw32-make.',
  );
}

Future<bool> _canExecute(
  String executable,
  List<String> args, {
  Map<String, String>? env,
}) async {
  try {
    final result = await Process.run(
      executable,
      args,
      environment: env,
      runInShell: Platform.isWindows,
    );
    return result.exitCode == 0;
  } on ProcessException {
    return false;
  }
}

Future<void> _runStreaming(
  String executable,
  List<String> args, {
  required String workingDirectory,
  Map<String, String>? environment,
}) async {
  stdout.writeln('  \$ $executable ${args.join(' ')}');
  final process = await Process.start(
    executable,
    args,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: Platform.isWindows && !executable.endsWith('.exe') && !executable.endsWith('.bat'),
  );

  final stdoutFuture = process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(stdout.writeln);
  final stderrFuture = process.stderr
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .forEach(stderr.writeln);

  final code = await process.exitCode;
  await Future.wait([stdoutFuture, stderrFuture]);

  if (code != 0) {
    throw _SetupException(
      'Command failed with exit code $code: $executable ${args.join(' ')}',
    );
  }
}

String _emccExecutablePath(String emsdkRoot) {
  final fileName = Platform.isWindows ? 'emcc.bat' : 'emcc';
  return _joinPath(emsdkRoot, 'upstream/emscripten/$fileName');
}

String _resolveAbsolutePath(String baseDir, String maybeRelative) {
  final normalized = maybeRelative.replaceAll('\\', '/');
  final isAbsolute =
      normalized.startsWith('/') ||
      RegExp(r'^[A-Za-z]:/').hasMatch(normalized);
  if (isAbsolute) {
    return maybeRelative;
  }
  return _joinPath(baseDir, maybeRelative);
}

String _joinPath(String a, String b) {
  final sep = Platform.pathSeparator;
  final left = a.endsWith('/') || a.endsWith('\\')
      ? a.substring(0, a.length - 1)
      : a;
  final right = b
      .replaceAll('/', sep)
      .replaceAll('\\', sep)
      .replaceFirst(RegExp('^${RegExp.escape(sep)}+'), '');
  return '$left$sep$right';
}

final class _SetupException implements Exception {
  final String message;
  const _SetupException(this.message);
}
