import 'dart:io';

import 'package:ffigen/ffigen.dart';

Future<void> main() async {
  final packageRoot = Platform.script.resolve('../');
  final engineCoreDir = packageRoot.resolve(
    'packages/muse_audio_engine/engine_core/',
  );
  final entryHeader = engineCoreDir.resolve('muse_engine_c_api.h');
  final outputDart = packageRoot.resolve(
    'lib/bridge/native/muse_engine_bindings.g.dart',
  );

  const includedStructs = <String>{
    'MuseEngineOpaque',
    'MuseHardwareConfig',
    'MuseSoundFontPresetPod',
    'MutationCommand',
    'SynthNoteEvent',
    'TakePlaybackStereoFrame',
    'TelemetryFrame',
    'FinalizedCaptureReceipt',
  };

  const includedTypealiases = <String>{
    'MuseEngineHandle',
    'MuseStatus',
    'MutationType',
    'SynthEventType',
  };

  bool shouldIncludeConstant(String name) =>
      name != 'MUSE_ENGINE_API' &&
      (name.startsWith('MUSE_') ||
          name.startsWith('MUT_') ||
          name.startsWith('EVT_') ||
          name.startsWith('k'));

  final generator = FfiGenerator(
    input: Input(
      entryPoints: [entryHeader],
      include: (header) =>
          header.toFilePath().startsWith(engineCoreDir.toFilePath()),
      compilerOptions: ['-std=c11', '-I${engineCoreDir.toFilePath()}'],
      appendCompilerOptions: true,
    ),
    output: Output(
      dart: DartOutput(path: outputDart),
      style: const NativeExternalBindings(
        assetId: 'package:muse_grid/bridge/native/muse_engine_bindings.g.dart',
      ),
      format: true,
      preamble: '''
// GENERATED CODE - DO NOT EDIT. Run: dart run tool/ffigen.dart

// ignore_for_file: type=lint, unused_import, unused_element, non_constant_identifier_names, camel_case_types
''',
    ),
    visitors: [
      Visitor(
        func: (node) {
          if (node.originalName.startsWith('muse_engine_')) {
            node.isIncluded = true;
          }
        },
        struct: (node) {
          if (includedStructs.contains(node.originalName)) {
            node.isIncluded = true;
          }
        },
        unnamedEnumConstant: (node) {
          if (shouldIncludeConstant(node.originalName)) {
            node.isIncluded = true;
          }
        },
        macroConstant: (node) {
          if (shouldIncludeConstant(node.originalName)) {
            node.isIncluded = true;
          }
        },
        typealias: (node) {
          if (includedTypealiases.contains(node.originalName)) {
            node.isIncluded = TypealiasInclude.always;
          }
        },
      ),
    ],
  );

  await generator.generate();
  stdout.writeln(
    'Generated FFI bindings at ${outputDart.toFilePath()}.',
  );
}
