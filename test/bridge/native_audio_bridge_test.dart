import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/bridge/native/native_audio_bridge.dart';
import 'package:muse_grid/bridge/native/platform_audio_permission.dart';
import 'package:path/path.dart' as p;

final class _FakePermissionChecker implements INativeAudioPermissionChecker {
  Result<void> nextResult;
  int callCount = 0;

  _FakePermissionChecker({
    this.nextResult = const Ok(null),
  });

  @override
  Future<Result<void>> ensureMicrophonePermission() async {
    callCount++;
    return nextResult;
  }
}

final class _FakeStorageLocator implements IInternalStorageLocator {
  final Directory rootDir;
  final Map<String, String> _casOverrides = <String, String>{};

  _FakeStorageLocator(this.rootDir);

  void registerCasPath(Sha256Digest sha256, String ext, String posixPath) {
    _casOverrides['${sha256.value}:$ext'] = posixPath;
  }

  @override
  String? resolveNativeCasPosixPath(
    Sha256Digest sha256, {
    required String ext,
  }) {
    final override = _casOverrides['${sha256.value}:$ext'];
    if (override != null) {
      return override;
    }
    if (sha256.value.length < MuseConstants.casShardHexLength) {
      return null;
    }
    final shard = sha256.value.substring(0, MuseConstants.casShardHexLength);
    return p.join(
      rootDir.path,
      MuseConstants.casDirName,
      shard,
      '${sha256.value}.$ext',
    );
  }

  @override
  String resolveRecordingStagingPath(TakeId takeId) {
    return p.join(
      rootDir.path,
      MuseConstants.stagingDirName,
      'rec_${takeId.value}.wav.part',
    );
  }

  @override
  Future<Result<List<int>>> readCasBlobBytes(
    Sha256Digest sha256, {
    required String ext,
  }) async {
    final posixPath = resolveNativeCasPosixPath(sha256, ext: ext);
    if (posixPath == null || !File(posixPath).existsSync()) {
      return Err(
        MuseError(
          MuseErrorCode.casBlobMissing,
          'Missing CAS blob for ${sha256.value}.$ext',
        ),
      );
    }
    return Ok(await File(posixPath).readAsBytes());
  }
}

Future<List<TelemetrySnapshot>> _pollTelemetryUntil(
  NativeAudioBridge bridge,
  bool Function(List<TelemetrySnapshot> collected) predicate, {
  Duration timeout = const Duration(seconds: 2),
}) async {
  final collected = <TelemetrySnapshot>[];
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final batch = bridge.drainTelemetry();
    if (batch.isNotEmpty) {
      collected.addAll(batch);
      if (predicate(collected)) {
        return collected;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 10));
  }
  return collected;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory tempDir;
  late _FakeStorageLocator storageLocator;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('muse_native_bridge_test_');
    storageLocator = _FakeStorageLocator(tempDir);
  });

  tearDown(() async {
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
  });

  group('PlatformAudioPermissionChecker', () {
    test('bypasses MethodChannel in headless CI mode even on Android', () async {
      var invoked = false;
      const channel = MethodChannel('musegrid/test_permissions_headless');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (call) async {
            invoked = true;
            return false;
          });
      addTearDown(
        () => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .setMockMethodCallHandler(channel, null),
      );

      final checker = PlatformAudioPermissionChecker(
        channel: channel,
        isAndroidOverride: true,
        environmentOverride: const <String, String>{
          MuseConstants.headlessAudioEnvVar:
              PlatformAudioPermissionChecker.headlessEnabledValue,
        },
      );

      final result = await checker.ensureMicrophonePermission();
      expect(result.isOk, isTrue);
      expect(invoked, isFalse);
    });

    test('fails closed on Android denial, null, PlatformException, or missing handler', () async {
      const channel = MethodChannel('musegrid/test_permissions_android');
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      addTearDown(() => messenger.setMockMethodCallHandler(channel, null));

      final checker = PlatformAudioPermissionChecker(
        channel: channel,
        isAndroidOverride: true,
        environmentOverride: const <String, String>{},
      );

      // Missing handler -> fail closed
      final missingRes = await checker.ensureMicrophonePermission();
      expect(missingRes, isA<Err<void>>());
      expect(
        (missingRes as Err<void>).error.code,
        MuseErrorCode.microphonePermissionDenied,
      );

      // Explicit denial (false) -> fail closed
      messenger.setMockMethodCallHandler(channel, (_) async => false);
      final deniedRes = await checker.ensureMicrophonePermission();
      expect(deniedRes, isA<Err<void>>());
      expect(
        (deniedRes as Err<void>).error.code,
        MuseErrorCode.microphonePermissionDenied,
      );

      // Null response -> fail closed
      messenger.setMockMethodCallHandler(channel, (_) async => null);
      final nullRes = await checker.ensureMicrophonePermission();
      expect(nullRes, isA<Err<void>>());
      expect(
        (nullRes as Err<void>).error.code,
        MuseErrorCode.microphonePermissionDenied,
      );

      // PlatformException -> fail closed
      messenger.setMockMethodCallHandler(
        channel,
        (_) => throw PlatformException(code: 'NO_ACTIVITY'),
      );
      final errRes = await checker.ensureMicrophonePermission();
      expect(errRes, isA<Err<void>>());
      expect(
        (errRes as Err<void>).error.code,
        MuseErrorCode.microphonePermissionDenied,
      );

      // Granted -> Ok
      messenger.setMockMethodCallHandler(channel, (_) async => true);
      final okRes = await checker.ensureMicrophonePermission();
      expect(okRes.isOk, isTrue);
    });
  });

  group('NativeAudioBridge Uninitialized & Permission Fail-Closed', () {
    test('rejects pre-initialization calls cleanly and throws StateError on currentHardwareInfo', () async {
      final permissions = _FakePermissionChecker(
        nextResult: const Err(
          MuseError(
            MuseErrorCode.microphonePermissionDenied,
            'Denied by test policy',
          ),
        ),
      );
      final bridge = NativeAudioBridge(
        storageLocator: storageLocator,
        permissionChecker: permissions,
      );
      addTearDown(bridge.dispose);

      expect(() => bridge.currentHardwareInfo, throwsStateError);
      expect(bridge.drainTelemetry(), isEmpty);
      expect(bridge.latestSnapshot, isNull);
      expect(bridge.play(), isA<Err<void>>());
      expect(bridge.pause(), isA<Err<void>>());
      expect(bridge.stop(), isA<Err<void>>());
      expect(bridge.seekToSample(const SampleFrame(0)), isA<Err<EpochId>>());
      expect(bridge.flushAndAdvanceEpoch(), isA<Err<EpochId>>());
      expect(bridge.setMonitorGain(0.5), isA<Err<void>>());

      final initDenied = await bridge.initialize();
      expect(initDenied, isA<Err<AudioHardwareInfo>>());
      expect(
        (initDenied as Err<AudioHardwareInfo>).error.code,
        MuseErrorCode.microphonePermissionDenied,
      );
      expect(permissions.callCount, 1);
      expect(() => bridge.currentHardwareInfo, throwsStateError);

      // Granting permission allows subsequent initialize() retry.
      permissions.nextResult = const Ok(null);
      final initOk = await bridge.initialize();
      expect(initOk, isA<Ok<AudioHardwareInfo>>());

      // Mid-session revocation blocks prepareAndStartCapture fail-closed.
      permissions.nextResult = const Err(
        MuseError(
          MuseErrorCode.microphonePermissionDenied,
          'Revoked before capture',
        ),
      );
      final captureDenied = await bridge.prepareAndStartCapture(
        const TakeId('take_denied'),
      );
      expect(captureDenied, isA<Err<void>>());
      expect(
        (captureDenied as Err<void>).error.code,
        MuseErrorCode.microphonePermissionDenied,
      );
    });
  });

  group('NativeAudioBridge Headless FFI Integration', () {
    test('initializes HAL, loads SF2, auditions note while paused with audible RMS, and unloads SF2', () async {
      final sf2File = File(MuseConstants.defaultSoundFontAssetPath);
      expect(
        sf2File.existsSync(),
        isTrue,
        reason: 'Bundled GeneralUser SF2 must exist at ${sf2File.path}',
      );

      const sf2Sha = Sha256Digest(MuseConstants.defaultSoundFontSha256);
      storageLocator.registerCasPath(sf2Sha, 'sf2', sf2File.absolute.path);

      final bridge = NativeAudioBridge(
        storageLocator: storageLocator,
        permissionChecker: _FakePermissionChecker(),
      );
      addTearDown(bridge.dispose);

      final initResult = await bridge.initialize();
      expect(initResult, isA<Ok<AudioHardwareInfo>>());
      final hw = (initResult as Ok<AudioHardwareInfo>).value;
      expect(hw.sampleRate, greaterThan(0));
      expect(hw.outputChannels, greaterThanOrEqualTo(2));
      expect(hw.outputBufferFrames, greaterThan(0));
      expect(hw.deviceFingerprint, isNotEmpty);
      if (Platform.environment[MuseConstants.headlessAudioEnvVar] ==
          PlatformAudioPermissionChecker.headlessEnabledValue) {
        expect(hw.deviceFingerprint, 'headless-miniaudio-null');
      }
      expect(bridge.currentHardwareInfo.sampleRate, hw.sampleRate);

      // Second initialize fails closed.
      final secondInit = await bridge.initialize();
      expect(secondInit, isA<Err<AudioHardwareInfo>>());
      expect(
        (secondInit as Err<AudioHardwareInfo>).error.code,
        MuseErrorCode.audioDeviceInitFailed,
      );

      // Missing CAS blob fails closed with casBlobMissing.
      const missingSha = Sha256Digest(
        '0000000000000000000000000000000000000000000000000000000000000000',
      );
      final missingSfResult = await bridge.loadSoundFontFromCas(
        sha256: missingSha,
      );
      expect(missingSfResult, isA<Err<LoadedSoundFontDescriptor>>());
      expect(
        (missingSfResult as Err<LoadedSoundFontDescriptor>).error.code,
        MuseErrorCode.casBlobMissing,
      );

      // Load bundled SoundFont and extract presets cleanly.
      final loadResult = await bridge.loadSoundFontFromCas(sha256: sf2Sha);
      expect(loadResult, isA<Ok<LoadedSoundFontDescriptor>>());
      final descriptor =
          (loadResult as Ok<LoadedSoundFontDescriptor>).value;
      expect(descriptor.handle.value, greaterThan(0));
      expect(descriptor.presets, isNotEmpty);
      expect(
        descriptor.presets.any((p) => p.bankNum == 0 && p.programNum == 0),
        isTrue,
      );

      // Assign patch + mix (+6 dB, pan -0.25) and trigger live audition while paused.
      final patchRes = bridge.assignChannelPatch(
        midiChannel: 0,
        sfHandle: descriptor.handle,
        bankNum: 0,
        programNum: 0,
      );
      expect(patchRes.isOk, isTrue);

      final mixRes = bridge.setChannelMix(
        midiChannel: 0,
        gainDb: 6.0,
        pan: -0.25,
      );
      expect(mixRes.isOk, isTrue);

      final auditionOn = bridge.triggerLiveAuditionNote(
        midiChannel: 0,
        pitchMidi: 60,
        velocity: 112,
        isNoteOn: true,
      );
      expect(auditionOn.isOk, isTrue);

      final audibleTelemetry = await _pollTelemetryUntil(
        bridge,
        (frames) => frames.any(
          (f) => !f.isPlaying && (f.outputRmsL > 0.0 || f.outputRmsR > 0.0),
        ),
      );
      expect(
        audibleTelemetry.any(
          (f) => !f.isPlaying && (f.outputRmsL > 0.0 || f.outputRmsR > 0.0),
        ),
        isTrue,
      );
      expect(bridge.latestSnapshot, isNotNull);

      expect(
        bridge
            .triggerLiveAuditionNote(
              midiChannel: 0,
              pitchMidi: 60,
              velocity: 0,
              isNoteOn: false,
            )
            .isOk,
        isTrue,
      );
      expect(bridge.silenceChannel(0).isOk, isTrue);

      final unloadRes = await bridge.unloadSoundFont(descriptor.handle);
      expect(unloadRes.isOk, isTrue);
    });

    test('enforces monotonic epochs, loop/schedule/take bounds, and fail-closed validation', () async {
      final bridge = NativeAudioBridge(
        storageLocator: storageLocator,
        permissionChecker: _FakePermissionChecker(),
      );
      addTearDown(bridge.dispose);

      expect((await bridge.initialize()).isOk, isTrue);
      expect(bridge.currentEpoch.value, 0);

      final epoch1 = bridge.flushAndAdvanceEpoch();
      expect((epoch1 as Ok<EpochId>).value.value, 1);
      expect(bridge.currentEpoch.value, 1);

      final epoch2 = bridge.seekToSample(const SampleFrame(4800));
      expect((epoch2 as Ok<EpochId>).value.value, 2);
      expect(bridge.currentEpoch.value, 2);

      // Invalid seek must not advance epoch.
      final badSeek = bridge.seekToSample(const SampleFrame(-1));
      expect(badSeek, isA<Err<EpochId>>());
      expect((badSeek as Err<EpochId>).error.code, MuseErrorCode.invalidTickRange);
      expect(bridge.currentEpoch.value, 2);

      // Invalid loop range fails closed.
      final badLoop = bridge.setLoopRegion(
        enabled: true,
        startFrame: const SampleFrame(1000),
        endFrame: const SampleFrame(1000),
      );
      expect(badLoop, isA<Err<void>>());
      expect((badLoop as Err<void>).error.code, MuseErrorCode.invalidTickRange);

      expect(
        bridge
            .setLoopRegion(
              enabled: true,
              startFrame: const SampleFrame(1000),
              endFrame: const SampleFrame(9600),
            )
            .isOk,
        isTrue,
      );

      // Schedule valid MIDI events and confirm watermark + count.
      final scheduledRes = bridge.scheduleEvents([
        ScheduledMidiEvent(
          epoch: bridge.currentEpoch,
          targetSampleFrame: const SampleFrame(4800),
          type: MuseConstants.midiEventNoteOn,
          channel: 0,
          data1: 64,
          data2: 96,
        ),
        ScheduledMidiEvent(
          epoch: bridge.currentEpoch,
          targetSampleFrame: const SampleFrame(9600),
          type: MuseConstants.midiEventNoteOff,
          channel: 0,
          data1: 64,
          data2: 0,
        ),
      ]);
      expect(scheduledRes, isA<Ok<int>>());
      expect((scheduledRes as Ok<int>).value, 2);
      expect((bridge.scheduleEvents(const []) as Ok<int>).value, 0);
      expect(
        (bridge.scheduleEvents(
                  const [],
                  scheduledUpToFrame: const SampleFrame(14400),
                )
                as Ok<int>)
            .value,
        0,
      );
      final badWatermarkRes = bridge.scheduleEvents(
        const [],
        scheduledUpToFrame: const SampleFrame(-1),
      );
      expect(badWatermarkRes, isA<Err<int>>());
      expect(
        (badWatermarkRes as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      // Out-of-range MIDI channel (16) or pitch bend fails closed locally.
      final badChannelEvent = bridge.scheduleEvents([
        ScheduledMidiEvent(
          epoch: bridge.currentEpoch,
          targetSampleFrame: const SampleFrame(4800),
          type: MuseConstants.midiEventNoteOn,
          channel: 16,
          data1: 60,
          data2: 100,
        ),
      ]);
      expect(badChannelEvent, isA<Err<int>>());
      expect(
        (badChannelEvent as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      final badPitchBendEvent = bridge.scheduleEvents([
        ScheduledMidiEvent(
          epoch: bridge.currentEpoch,
          targetSampleFrame: const SampleFrame(4800),
          type: MuseConstants.midiEventPitchBend,
          channel: 0,
          data1: 0,
          data2: 0,
          pitchBend: 8192,
        ),
      ]);
      expect(badPitchBendEvent, isA<Err<int>>());
      expect(
        (badPitchBendEvent as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      final badEpochEvent = bridge.scheduleEvents([
        const ScheduledMidiEvent(
          epoch: EpochId(-1),
          targetSampleFrame: SampleFrame(4800),
          type: MuseConstants.midiEventNoteOn,
          channel: 0,
          data1: 60,
          data2: 100,
        ),
      ]);
      expect(badEpochEvent, isA<Err<int>>());
      expect(
        (badEpochEvent as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      expect(
        (bridge.assignChannelPatch(
                  midiChannel: 16,
                  sfHandle: const SoundFontHandle(1),
                  bankNum: 0,
                  programNum: 0,
                )
                as Err<void>)
            .error
            .code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        (bridge.silenceChannel(-1) as Err<void>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        (bridge.setChannelMix(midiChannel: 0, gainDb: double.nan, pan: 0.0)
                as Err<void>)
            .error
            .code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        (bridge.triggerLiveAuditionNote(
                  midiChannel: 0,
                  pitchMidi: 128,
                  velocity: 100,
                  isNoteOn: true,
                )
                as Err<void>)
            .error
            .code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );
      expect(
        (bridge.setMonitorGain(-0.1) as Err<void>).error.code,
        MuseErrorCode.audioDeviceInitFailed,
      );
      expect(
        () => bridge.drainTelemetry(maxFrames: 0),
        throwsArgumentError,
      );

      // 17 active take regions (> maxActiveTakeRegions = 16) fails closed.
      final tooManyRegions = List<ActiveTakePlaybackRegion>.generate(
        MuseConstants.maxActiveTakeRegions + 1,
        (idx) => ActiveTakePlaybackRegion(
          takeId: TakeId('take_$idx'),
          partId: PartId('part_$idx'),
          wavSha256: const Sha256Digest(
            'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
          ),
          startSampleFrame: const SampleFrame(0),
          durationFrames: 1024,
          gainDb: 0.0,
          pan: 0.0,
        ),
      );
      final overflowTakesRes = await bridge.syncActiveTakeRegions(
        tooManyRegions,
      );
      expect(overflowTakesRes, isA<Err<void>>());
      expect(
        (overflowTakesRes as Err<void>).error.code,
        MuseErrorCode.takeLoadFailed,
      );

      // Missing CAS WAV blob fails closed with casBlobMissing.
      final missingWavRes = await bridge.syncActiveTakeRegions([
        const ActiveTakePlaybackRegion(
          takeId: TakeId('missing_take'),
          partId: PartId('part_0'),
          wavSha256: Sha256Digest(
            'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          ),
          startSampleFrame: SampleFrame(0),
          durationFrames: 1024,
          gainDb: 0.0,
          pan: 0.0,
        ),
      ]);
      expect(missingWavRes, isA<Err<void>>());
      expect(
        (missingWavRes as Err<void>).error.code,
        MuseErrorCode.casBlobMissing,
      );

      // Stop pauses playback and advances epoch cleanly.
      expect(bridge.play().isOk, isTrue);
      expect(bridge.stop().isOk, isTrue);
      expect(bridge.currentEpoch.value, 3);
      final postStopTelemetry = await _pollTelemetryUntil(
        bridge,
        (frames) => frames.any((f) => f.activeEpoch.value == 3 && !f.isPlaying),
      );
      expect(
        postStopTelemetry.any((f) => f.activeEpoch.value == 3 && !f.isPlaying),
        isTrue,
      );
    });

    test('records WAV via Butler, finalizes receipt with matching SHA-256, and registers active take playback', () async {
      final bridge = NativeAudioBridge(
        storageLocator: storageLocator,
        permissionChecker: _FakePermissionChecker(),
      );
      addTearDown(bridge.dispose);

      expect((await bridge.initialize()).isOk, isTrue);
      expect(bridge.setMonitorGain(0.5).isOk, isTrue);

      const takeId = TakeId('take_capture_01');
      final startRes = await bridge.prepareAndStartCapture(takeId);
      expect(startRes.isOk, isTrue);

      // Wait until live RT audio callbacks run while capture is armed.
      final captureTelemetry = await _pollTelemetryUntil(
        bridge,
        (frames) => frames.where((f) => f.isCapturing).length >= 3,
      );
      expect(captureTelemetry.any((f) => f.isCapturing), isTrue);

      final stopRes = await bridge.stopAndFinalizeCapture(takeId);
      expect(stopRes, isA<Ok<RecordingCaptureReceipt>>());
      final receipt = (stopRes as Ok<RecordingCaptureReceipt>).value;

      expect(receipt.takeId, takeId);
      expect(receipt.durationFrames, greaterThan(0));
      expect(receipt.sampleRate, bridge.currentHardwareInfo.sampleRate);
      expect(receipt.channelCount, greaterThan(0));

      final stagedFile = File(receipt.stagingPath);
      expect(stagedFile.existsSync(), isTrue);
      final actualSha256 = sha256.convert(await stagedFile.readAsBytes()).toString();
      expect(receipt.sha256.value, actualSha256);

      // Promote captured WAV into CAS layout and register via syncActiveTakeRegions.
      final casPath = storageLocator.resolveNativeCasPosixPath(
        receipt.sha256,
        ext: 'wav',
      )!;
      await Directory(p.dirname(casPath)).create(recursive: true);
      await stagedFile.copy(casPath);

      final syncRes = await bridge.syncActiveTakeRegions([
        ActiveTakePlaybackRegion(
          takeId: takeId,
          partId: const PartId('part_vocal'),
          wavSha256: receipt.sha256,
          startSampleFrame: const SampleFrame(0),
          durationFrames: receipt.durationFrames,
          gainDb: 0.0,
          pan: 0.0,
        ),
      ]);
      expect(syncRes.isOk, isTrue);
      expect((await bridge.syncActiveTakeRegions(const [])).isOk, isTrue);
    });

    test('dispose waits cleanly for in-flight Isolate.run operations and is idempotent', () async {
      final sf2File = File(MuseConstants.defaultSoundFontAssetPath);
      const sf2Sha = Sha256Digest(MuseConstants.defaultSoundFontSha256);
      storageLocator.registerCasPath(sf2Sha, 'sf2', sf2File.absolute.path);

      final bridge = NativeAudioBridge(
        storageLocator: storageLocator,
        permissionChecker: _FakePermissionChecker(),
      );
      expect((await bridge.initialize()).isOk, isTrue);

      final loadFuture = bridge.loadSoundFontFromCas(sha256: sf2Sha);
      final disposeFuture = bridge.dispose();
      final secondDispose = bridge.dispose();

      final results = await Future.wait<Object?>([
        loadFuture,
        disposeFuture,
        secondDispose,
      ]);
      final loadRes = results.first as Result<LoadedSoundFontDescriptor>;
      expect(loadRes, isA<Ok<LoadedSoundFontDescriptor>>());
      expect(() => bridge.currentHardwareInfo, throwsStateError);
    });
  });
}
