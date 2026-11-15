import 'dart:io';

import 'package:code_assets/code_assets.dart';
import 'package:hooks/hooks.dart';
import 'package:native_toolchain_c/native_toolchain_c.dart';

void main(List<String> args) async {
  await build(args, (input, output) async {
    if (!input.config.buildCodeAssets) {
      return;
    }

    final targetOS = input.config.code.targetOS;
    final targetArch = input.config.code.targetArchitecture;
    final iosSdk = targetOS == OS.iOS ? input.config.code.iOS.targetSdk : null;
    final resolvedBuild = _resolveBuildArchives(
      packageRoot: input.packageRoot,
      targetOS: targetOS,
      targetArch: targetArch,
      iosSdk: iosSdk,
    );
    final cmakeBuildRelDir = resolvedBuild.cmakeBuildRelDir;
    final cmakeBuildUri = resolvedBuild.cmakeBuildUri;
    final fluidsynthLib = resolvedBuild.fluidsynthLib;
    final miniaudioLib = resolvedBuild.miniaudioLib;

    if (fluidsynthLib == null || miniaudioLib == null) {
      throw StateError(
        'Missing prebuilt audio engine static archives for '
        '${targetOS.name}/${targetArch.name} in ${cmakeBuildUri.toFilePath()}. '
        'Run `dart run tool/setup_audio_engine.dart` (for host and macOS '
        'universal architectures) or configure and build CMake into '
        '`$cmakeBuildRelDir` before building.',
      );
    }

    final includes = _resolveIncludeDirectories(
      cmakeBuildUri: cmakeBuildUri,
      targetOS: targetOS,
      targetArch: targetArch,
    );
    final frameworks = _frameworksForOS(targetOS);
    final osLibraries = _librariesForOS(targetOS);
    final fluidsynthLinkName = _libraryLinkName(fluidsynthLib, targetOS);
    final miniaudioLinkName = _libraryLinkName(miniaudioLib, targetOS);
    final compilerFlags = _compilerFlagsForBuild(input.config.code);

    final builder = CBuilder.library(
      name: 'muse_audio_engine',
      assetName: 'bridge/native/muse_engine_bindings.g.dart',
      language: Language.cpp,
      std: 'c++17',
      cppLinkStdLib: targetOS == OS.android ? 'c++_static' : null,
      sources: const [
        'packages/muse_audio_engine/engine_core/audio_engine_core.cpp',
        'packages/muse_audio_engine/engine_core/butler_worker.cpp',
        'packages/muse_audio_engine/engine_core/muse_engine_c_api.cpp',
        'packages/muse_audio_engine/native/miniaudio_duplex_hal.cpp',
      ],
      includes: includes,
      flags: compilerFlags,
      defines: const {
        'FLUIDSYNTH_NOT_A_DLL': null,
        'MUSE_ENGINE_BUILD_SHARED': null,
      },
      libraryDirectories: [
        fluidsynthLib.parent.path,
        miniaudioLib.parent.path,
      ],
      frameworks: frameworks,
      libraries: [fluidsynthLinkName, miniaudioLinkName, ...osLibraries],
    );

    await builder.run(input: input, output: output);
    output.dependencies.addAll([fluidsynthLib.uri, miniaudioLib.uri]);
  });
}

({
  String cmakeBuildRelDir,
  Uri cmakeBuildUri,
  File? fluidsynthLib,
  File? miniaudioLib,
}) _resolveBuildArchives({
  required Uri packageRoot,
  required OS targetOS,
  required Architecture targetArch,
  IOSSdk? iosSdk,
}) {
  final targetSpecific = targetOS == OS.iOS && iosSdk != null
      ? 'packages/muse_audio_engine/.build_ios_${iosSdk.type}_${targetArch.name}/'
      : 'packages/muse_audio_engine/.build_${targetOS.name}_${targetArch.name}/';
  final isHostTarget =
      targetOS == OS.current && targetArch == Architecture.current;
  final candidates = <String>[
    targetSpecific,
    if (isHostTarget) 'packages/muse_audio_engine/.build/',
  ];

  for (final relDir in candidates) {
    final uri = packageRoot.resolve(relDir);
    final fluidsynth = _resolveArchiveFile(
      cmakeBuildUri: uri,
      targetOS: targetOS,
      candidates: const [
        '_deps/fluidsynth-build/src/libfluidsynth.a',
        '_deps/fluidsynth-build/src/Release/libfluidsynth-3.lib',
        '_deps/fluidsynth-build/src/libfluidsynth-3.lib',
        '_deps/fluidsynth-build/src/Release/fluidsynth.lib',
        '_deps/fluidsynth-build/src/fluidsynth.lib',
      ],
    );
    final miniaudio = _resolveArchiveFile(
      cmakeBuildUri: uri,
      targetOS: targetOS,
      candidates: const [
        '_deps/miniaudio-build/libminiaudio.a',
        '_deps/miniaudio-build/Release/miniaudio.lib',
        '_deps/miniaudio-build/miniaudio.lib',
      ],
    );
    if (fluidsynth != null && miniaudio != null) {
      return (
        cmakeBuildRelDir: relDir,
        cmakeBuildUri: uri,
        fluidsynthLib: fluidsynth,
        miniaudioLib: miniaudio,
      );
    }
    if (!isHostTarget) {
      return (
        cmakeBuildRelDir: relDir,
        cmakeBuildUri: uri,
        fluidsynthLib: fluidsynth,
        miniaudioLib: miniaudio,
      );
    }
  }

  const fallbackRelDir = 'packages/muse_audio_engine/.build/';
  return (
    cmakeBuildRelDir: fallbackRelDir,
    cmakeBuildUri: packageRoot.resolve(fallbackRelDir),
    fluidsynthLib: null,
    miniaudioLib: null,
  );
}

List<String> _resolveIncludeDirectories({
  required Uri cmakeBuildUri,
  required OS targetOS,
  required Architecture targetArch,
}) {
  final cmakeCache = _readCmakeCache(cmakeBuildUri);
  final fluidsynthSrc = _resolveSourceDir(
    cmakeBuildUri: cmakeBuildUri,
    cmakeCache: cmakeCache,
    cacheKeys: const ['FluidSynth_SOURCE_DIR', 'FETCHCONTENT_SOURCE_DIR_FLUIDSYNTH'],
    defaultRelPath: '_deps/fluidsynth-src',
  );
  final miniaudioSrc = _resolveSourceDir(
    cmakeBuildUri: cmakeBuildUri,
    cmakeCache: cmakeCache,
    cacheKeys: const ['miniaudio_SOURCE_DIR', 'FETCHCONTENT_SOURCE_DIR_MINIAUDIO'],
    defaultRelPath: '_deps/miniaudio-src',
  );
  final picosha2Src = _resolveSourceDir(
    cmakeBuildUri: cmakeBuildUri,
    cmakeCache: cmakeCache,
    cacheKeys: const ['picosha2_SOURCE_DIR', 'FETCHCONTENT_SOURCE_DIR_PICOSHA2'],
    defaultRelPath: '_deps/picosha2-src',
  );

  final resolvedDepsIncludes = <String>[
    Directory.fromUri(fluidsynthSrc.uri.resolve('include/')).path,
    Directory.fromUri(cmakeBuildUri.resolve('_deps/fluidsynth-build/include/')).path,
    miniaudioSrc.path,
    picosha2Src.path,
  ];

  for (final includePath in resolvedDepsIncludes) {
    if (!Directory(includePath).existsSync()) {
      throw StateError(
        'Missing audio engine dependency include directory for '
        '${targetOS.name}/${targetArch.name}: $includePath. '
        'Run `dart run tool/setup_audio_engine.dart` before building.',
      );
    }
  }

  return [
    'packages/muse_audio_engine/engine_core',
    'packages/muse_audio_engine/native',
    ...resolvedDepsIncludes,
  ];
}

Directory _resolveSourceDir({
  required Uri cmakeBuildUri,
  required Map<String, String> cmakeCache,
  required List<String> cacheKeys,
  required String defaultRelPath,
}) {
  for (final key in cacheKeys) {
    final cached = cmakeCache[key];
    if (cached != null && cached.isNotEmpty) {
      final dir = Directory(cached);
      if (dir.existsSync()) {
        return dir;
      }
    }
  }
  return Directory.fromUri(cmakeBuildUri.resolve('$defaultRelPath/'));
}

Map<String, String> _readCmakeCache(Uri cmakeBuildUri) {
  final cacheFile = File.fromUri(cmakeBuildUri.resolve('CMakeCache.txt'));
  if (!cacheFile.existsSync()) {
    return const {};
  }
  final entries = <String, String>{};
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
    entries[key] = trimmed.substring(eqIndex + 1);
  }
  return entries;
}

File? _resolveArchiveFile({
  required Uri cmakeBuildUri,
  required OS targetOS,
  required List<String> candidates,
}) {
  for (final rel in candidates) {
    if (targetOS != OS.windows && rel.endsWith('.lib')) {
      continue;
    }
    final file = File.fromUri(cmakeBuildUri.resolve(rel));
    if (file.existsSync()) {
      return file;
    }
  }
  return null;
}

List<String> _frameworksForOS(OS targetOS) {
  if (targetOS == OS.macOS) {
    return const [
      'Foundation',
      'CoreFoundation',
      'CoreAudio',
      'AudioToolbox',
      'CoreServices',
      'AudioUnit',
    ];
  }
  if (targetOS == OS.iOS) {
    return const [
      'Foundation',
      'AVFoundation',
      'AudioToolbox',
      'CoreAudio',
      'CoreFoundation',
    ];
  }
  return const [];
}

List<String> _librariesForOS(OS targetOS) {
  if (targetOS == OS.android) {
    // miniaudio loads libaaudio.so and libOpenSLES.so via dlopen at runtime,
    // keeping NDK API < 27 builds linkable without a static libaaudio.so stub.
    return const ['log', 'm', 'dl'];
  }
  if (targetOS == OS.linux) {
    return const ['pthread', 'dl', 'm'];
  }
  if (targetOS == OS.windows) {
    return const ['ole32', 'winmm'];
  }
  return const [];
}

String _libraryLinkName(File archiveFile, OS targetOS) {
  final fileName = archiveFile.uri.pathSegments.last;
  if (targetOS == OS.windows && fileName.endsWith('.lib')) {
    return fileName.substring(0, fileName.length - '.lib'.length);
  }
  if (fileName.startsWith('lib') && fileName.endsWith('.a')) {
    return fileName.substring('lib'.length, fileName.length - '.a'.length);
  }
  return fileName;
}

List<String> _compilerFlagsForBuild(CodeConfig codeConfig) {
  if (codeConfig.targetOS != OS.windows) {
    return const [];
  }
  final compilerName =
      codeConfig.cCompiler?.compiler.pathSegments.last.toLowerCase();
  final usesMsvcDriver = compilerName == null ||
      compilerName == 'cl.exe' ||
      compilerName == 'cl' ||
      compilerName == 'clang-cl.exe' ||
      compilerName == 'clang-cl';
  // Match CMake Release static archive CRT (/MD) across Debug and Release builds.
  return usesMsvcDriver ? const ['/MD'] : const ['-fms-runtime-lib=dll'];
}
