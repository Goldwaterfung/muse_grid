@TestOn('browser')
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/bridge/web/web_audio_protocol.dart';
import 'package:muse_grid/bridge/web/web_audio_worklet_bridge.dart';

final class _FakeStorageLocator implements IInternalStorageLocator {
  final Map<String, Uint8List> blobs = <String, Uint8List>{};

  @override
  String? resolveNativeCasPosixPath(Sha256Digest sha256, {required String ext}) =>
      null;

  @override
  String resolveRecordingStagingPath(TakeId takeId) =>
      '/staging/rec_${takeId.value}.wav.part';

  @override
  Future<Result<List<int>>> readCasBlobBytes(
    Sha256Digest sha256, {
    required String ext,
  }) async {
    final key = '${sha256.value}.$ext';
    final data = blobs[key];
    if (data == null) {
      return Err(
        MuseError(MuseErrorCode.casBlobMissing, 'Missing CAS blob $key'),
      );
    }
    return Ok(data);
  }
}

final class _FakeWebBackend implements WebAudioHostBackend {
  @override
  bool isSecureContext = true;

  Result<AudioHardwareInfo> startSessionResult = const Ok(
    AudioHardwareInfo(
      sampleRate: 48000,
      inputChannels: 1,
      outputChannels: 2,
      inputBufferFrames: RiffWavCodec.webRenderQuantumFrames,
      outputBufferFrames: RiffWavCodec.webRenderQuantumFrames,
      deviceFingerprint: 'fake-web-worklet',
    ),
  );

  void Function(List<TelemetrySnapshot>)? _onTelemetryBatch;
  void Function()? _onUnexpectedDisconnect;
  void Function(MuseError error)? _onAsyncError;
  final List<int> pushedMutations = <int>[];
  final List<({int mutationType, int targetEpoch, int sampleFrameA})>
  pushedMutationDetails =
      <({int mutationType, int targetEpoch, int sampleFrameA})>[];
  final List<ScheduledMidiEvent> pushedEvents = <ScheduledMidiEvent>[];
  final List<String> registeredTakeIds = <String>[];
  final List<({int epoch, int startSampleFrame, int frameCount})>
  pushedTakeChunks = <({int epoch, int startSampleFrame, int frameCount})>[];
  int clearedTakeCalls = 0;
  int pushedTakeFrames = 0;
  int prepareCaptureCalls = 0;
  bool disposed = false;
  bool captureOverflowed = false;
  Completer<Result<void>>? prepareCaptureGate;
  Completer<Result<WebCaptureFinalizedResult>>? stopCaptureGate;
  Uint8List capturedFileBytes = Uint8List.fromList(utf8.encode('RIFF-fake-wav'));

  @override
  Future<Result<AudioHardwareInfo>> startSession({
    required void Function(List<TelemetrySnapshot> frames) onTelemetryBatch,
    required void Function() onUnexpectedDisconnect,
    void Function(MuseError error)? onAsyncError,
  }) async {
    _onTelemetryBatch = onTelemetryBatch;
    _onUnexpectedDisconnect = onUnexpectedDisconnect;
    _onAsyncError = onAsyncError;
    return startSessionResult;
  }

  void emitTelemetry(TelemetrySnapshot snapshot) {
    _onTelemetryBatch?.call(<TelemetrySnapshot>[snapshot]);
  }

  void emitAsyncError(MuseError error) {
    _onAsyncError?.call(error);
    if (error.code == MuseErrorCode.audioDeviceInitFailed) {
      _onUnexpectedDisconnect?.call();
    }
  }

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSf2Bytes({
    required Sha256Digest sha256,
    required Uint8List bytes,
  }) async {
    return const Ok(
      LoadedSoundFontDescriptor(
        handle: SoundFontHandle(7),
        presets: <SoundFontPresetInfo>[
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Piano'),
        ],
      ),
    );
  }

  @override
  Future<Result<void>> unloadSf2(int sfHandle) async => const Ok(null);

  @override
  Result<void> pushMutation({
    required int mutationType,
    int channel = 0,
    int flagA = 0,
    int intParamA = 0,
    int intParamB = 0,
    int intParamC = 0,
    double floatParamA = 0.0,
    double floatParamB = 0.0,
    int targetEpoch = 0,
    int sampleFrameA = 0,
    int sampleFrameB = 0,
  }) {
    pushedMutations.add(mutationType);
    pushedMutationDetails.add((
      mutationType: mutationType,
      targetEpoch: targetEpoch,
      sampleFrameA: sampleFrameA,
    ));
    return const Ok(null);
  }

  @override
  Result<int> pushEvents(List<ScheduledMidiEvent> events) {
    pushedEvents.addAll(events);
    return Ok(events.length);
  }

  @override
  Future<Result<void>> clearActiveTakes() async {
    clearedTakeCalls++;
    registeredTakeIds.clear();
    return const Ok(null);
  }

  @override
  Future<Result<void>> registerActiveTake({
    required String takeId,
    required String casPath,
    required int startSampleFrame,
    required int durationFrames,
    required double gainDb,
    required double pan,
  }) async {
    registeredTakeIds.add(takeId);
    return const Ok(null);
  }

  @override
  Future<Result<int>> pushTakePcm({
    required int epoch,
    required int startSampleFrame,
    required Float32List interleavedStereoF32,
    required int frameCount,
  }) async {
    pushedTakeFrames += frameCount;
    pushedTakeChunks.add((
      epoch: epoch,
      startSampleFrame: startSampleFrame,
      frameCount: frameCount,
    ));
    return Ok(frameCount);
  }

  @override
  Future<Result<void>> prepareAndStartCapture({
    required String stagingPath,
    required AudioHardwareInfo hardwareInfo,
  }) async {
    prepareCaptureCalls++;
    final gate = prepareCaptureGate;
    if (gate != null) {
      return gate.future;
    }
    return const Ok(null);
  }

  @override
  Future<Result<WebCaptureFinalizedResult>> stopAndFinalizeCapture({
    required String stagingPath,
  }) async {
    final gate = stopCaptureGate;
    if (gate != null) {
      return gate.future;
    }
    return Ok(
      WebCaptureFinalizedResult(
        durationFrames: 4096,
        capturedSampleClock: 1024,
        capturedPlayheadFrame: 256,
        hasOverflowed: captureOverflowed,
      ),
    );
  }

  @override
  Future<Result<String>> computeOpfsFileSha256(String stagingPath) async {
    return Ok(sha256.convert(capturedFileBytes).toString());
  }

  @override
  Future<void> dispose() async {
    disposed = true;
  }
}

Uint8List _makeMinimalStereoWav({
  required int sampleRate,
  required int frames,
}) {
  final dataBytes = frames * 2 * 2;
  final header = RiffWavCodec.buildPcm16Header(
    sampleRate: sampleRate,
    channelCount: 2,
    dataByteLength: dataBytes,
  );
  final out = Uint8List(header.length + dataBytes);
  out.setAll(0, header);
  final bd = ByteData.view(out.buffer);
  for (var i = 0; i < frames * 2; i++) {
    bd.setInt16(header.length + i * 2, 8192, Endian.little);
  }
  return out;
}

void main() {
  test('currentHardwareInfo throws StateError before initialize()', () {
    final storage = _FakeStorageLocator();
    final backend = _FakeWebBackend();
    final bridge = WebAudioWorkletBridge(
      storageLocator: storage,
      backend: backend,
    );

    expect(() => bridge.currentHardwareInfo, throwsStateError);
  });

  test('fails closed on insecure origin and respects SoundFont playing/size gates', () async {
    final storage = _FakeStorageLocator();
    final backend = _FakeWebBackend()..isSecureContext = false;
    final bridge = WebAudioWorkletBridge(
      storageLocator: storage,
      backend: backend,
    );

    final insecureRes = await bridge.initialize();
    expect(insecureRes.isErr, isTrue);
    expect(
      (insecureRes as Err<AudioHardwareInfo>).error.code,
      MuseErrorCode.webAudioUserGestureRequired,
    );

    backend.isSecureContext = true;
    final initRes = await bridge.initialize();
    expect(initRes.isOk, isTrue);
    expect(bridge.currentHardwareInfo.sampleRate, 48000);

    // Missing CAS blob fails closed.
    final missingRes = await bridge.loadSoundFontFromCas(
      sha256: const Sha256Digest('missing_sf2_sha'),
    );
    expect(missingRes.isErr, isTrue);
    expect(
      (missingRes as Err<LoadedSoundFontDescriptor>).error.code,
      MuseErrorCode.casBlobMissing,
    );

    // Playing state rejects Web SF2 load immediately.
    expect(bridge.play().isOk, isTrue);
    final playingRes = await bridge.loadSoundFontFromCas(
      sha256: const Sha256Digest('valid_sf2_sha'),
    );
    expect(playingRes.isErr, isTrue);
    expect(
      (playingRes as Err<LoadedSoundFontDescriptor>).error.code,
      MuseErrorCode.webSoundFontLoadWhilePlaying,
    );

    // Paused/stopped allows valid SF2 bytes <= 64 MiB.
    expect(bridge.pause().isOk, isTrue);
    storage.blobs['valid_sf2_sha.sf2'] = Uint8List.fromList(<int>[1, 2, 3, 4]);
    final sfRes = await bridge.loadSoundFontFromCas(
      sha256: const Sha256Digest('valid_sf2_sha'),
    );
    expect(sfRes.isOk, isTrue);
    expect((sfRes as Ok<LoadedSoundFontDescriptor>).value.handle.value, 7);

    await bridge.dispose();
    expect(backend.disposed, isTrue);
  });

  test('syncActiveTakeRegions, capture receipt SHA-256, and overflow fail closed', () async {
    final storage = _FakeStorageLocator();
    final backend = _FakeWebBackend();
    final bridge = WebAudioWorkletBridge(
      storageLocator: storage,
      backend: backend,
    );
    expect((await bridge.initialize()).isOk, isTrue);

    storage.blobs['take_sha.wav'] = _makeMinimalStereoWav(
      sampleRate: 48000,
      frames: 512,
    );
    final syncRes = await bridge.syncActiveTakeRegions(const <ActiveTakePlaybackRegion>[
      ActiveTakePlaybackRegion(
        takeId: TakeId('take-1'),
        partId: PartId('part-1'),
        wavSha256: Sha256Digest('take_sha'),
        startSampleFrame: SampleFrame(0),
        durationFrames: 512,
        gainDb: 0.0,
        pan: 0.0,
      ),
    ]);
    expect(syncRes.isOk, isTrue);
    expect(backend.registeredTakeIds, equals(<String>['take-1']));
    expect(backend.pushedTakeFrames, 512);

    // Start & finalize capture verifies receipt fields & SHA-256.
    expect((await bridge.prepareAndStartCapture(const TakeId('take-2'))).isOk, isTrue);
    final finRes = await bridge.stopAndFinalizeCapture(const TakeId('take-2'));
    expect(finRes.isOk, isTrue);
    final receipt = (finRes as Ok<RecordingCaptureReceipt>).value;
    expect(receipt.durationFrames, 4096);
    expect(receipt.capturedSampleClock.value, 1024);
    expect(receipt.capturedPlayheadFrame.value, 256);
    expect(receipt.sha256.value, sha256.convert(backend.capturedFileBytes).toString());

    // Overflow fails closed cleanly.
    backend.captureOverflowed = true;
    expect((await bridge.prepareAndStartCapture(const TakeId('take-3'))).isOk, isTrue);
    final overRes = await bridge.stopAndFinalizeCapture(const TakeId('take-3'));
    expect(overRes.isErr, isTrue);
    expect(
      (overRes as Err<RecordingCaptureReceipt>).error.code,
      MuseErrorCode.captureBufferOverflow,
    );

    // Telemetry buffering & draining.
    backend.emitTelemetry(
      const TelemetrySnapshot(
        playheadSampleFrame: SampleFrame(512),
        activeEpoch: EpochId(0),
        outputPeakL: 0.4,
        outputPeakR: 0.4,
        outputRmsL: 0.2,
        outputRmsR: 0.2,
        inputPeak: 0.1,
        inputRms: 0.05,
        isPlaying: true,
        isCapturing: false,
        hasEventQueueUnderrun: false,
        hasCaptureBufferOverflow: false,
        hasTakePlaybackUnderrun: false,
      ),
    );
    expect(bridge.latestSnapshot?.playheadSampleFrame.value, 512);
    expect(bridge.drainTelemetry().length, 1);
    expect(bridge.drainTelemetry(), isEmpty);

    await bridge.dispose();
  });

  test(
    'seekToSample and stop reset telemetry playhead and ignore stale-epoch telemetry',
    () async {
      final storage = _FakeStorageLocator();
      final backend = _FakeWebBackend();
      final bridge = WebAudioWorkletBridge(
        storageLocator: storage,
        backend: backend,
      );
      expect((await bridge.initialize()).isOk, isTrue);

      storage.blobs['long_take.wav'] = _makeMinimalStereoWav(
        sampleRate: 48000,
        frames: 24000,
      );
      expect(
        (await bridge.syncActiveTakeRegions(const <ActiveTakePlaybackRegion>[
          ActiveTakePlaybackRegion(
            takeId: TakeId('take-long'),
            partId: PartId('part-long'),
            wavSha256: Sha256Digest('long_take'),
            startSampleFrame: SampleFrame(0),
            durationFrames: 24000,
            gainDb: 0.0,
            pan: 0.0,
          ),
        ])).isOk,
        isTrue,
      );
      await pumpEventQueue();

      final initialEpoch = bridge.currentEpoch;
      backend.emitTelemetry(
        TelemetrySnapshot(
          playheadSampleFrame: const SampleFrame(10000),
          activeEpoch: initialEpoch,
          outputPeakL: 0.1,
          outputPeakR: 0.1,
          outputRmsL: 0.05,
          outputRmsR: 0.05,
          inputPeak: 0.0,
          inputRms: 0.0,
          isPlaying: true,
          isCapturing: false,
          hasEventQueueUnderrun: false,
          hasCaptureBufferOverflow: false,
          hasTakePlaybackUnderrun: false,
        ),
      );
      await pumpEventQueue();

      backend.pushedTakeChunks.clear();
      final seekRes = bridge.seekToSample(const SampleFrame(0));
      expect(seekRes.isOk, isTrue);
      // Stale-epoch telemetry arrives right after seekToSample(0).
      backend.emitTelemetry(
        TelemetrySnapshot(
          playheadSampleFrame: const SampleFrame(12000),
          activeEpoch: initialEpoch,
          outputPeakL: 0.1,
          outputPeakR: 0.1,
          outputRmsL: 0.05,
          outputRmsR: 0.05,
          inputPeak: 0.0,
          inputRms: 0.0,
          isPlaying: true,
          isCapturing: false,
          hasEventQueueUnderrun: false,
          hasCaptureBufferOverflow: false,
          hasTakePlaybackUnderrun: false,
        ),
      );
      await pumpEventQueue();

      expect(backend.pushedTakeChunks, isNotEmpty);
      expect(backend.pushedTakeChunks.first.startSampleFrame, 0);
      expect(
        backend.pushedTakeChunks.every(
          (chunk) => chunk.epoch == bridge.currentEpoch.value,
        ),
        isTrue,
      );

      // Advance playhead again, stop(), then re-sync takes -> cursor must start at 0.
      backend.emitTelemetry(
        TelemetrySnapshot(
          playheadSampleFrame: const SampleFrame(10000),
          activeEpoch: bridge.currentEpoch,
          outputPeakL: 0.1,
          outputPeakR: 0.1,
          outputRmsL: 0.05,
          outputRmsR: 0.05,
          inputPeak: 0.0,
          inputRms: 0.0,
          isPlaying: true,
          isCapturing: false,
          hasEventQueueUnderrun: false,
          hasCaptureBufferOverflow: false,
          hasTakePlaybackUnderrun: false,
        ),
      );
      await pumpEventQueue();
      expect(bridge.stop().isOk, isTrue);
      backend.pushedTakeChunks.clear();
      expect(
        (await bridge.syncActiveTakeRegions(const <ActiveTakePlaybackRegion>[
          ActiveTakePlaybackRegion(
            takeId: TakeId('take-long'),
            partId: PartId('part-long'),
            wavSha256: Sha256Digest('long_take'),
            startSampleFrame: SampleFrame(0),
            durationFrames: 24000,
            gainDb: 0.0,
            pan: 0.0,
          ),
        ])).isOk,
        isTrue,
      );
      await pumpEventQueue();
      expect(backend.pushedTakeChunks.first.startSampleFrame, 0);

      await bridge.dispose();
    },
  );

  test(
    'loop prefetch handles short loops, loop wraps, and pre-loop playback cleanly',
    () async {
      final storage = _FakeStorageLocator();
      final backend = _FakeWebBackend();
      final bridge = WebAudioWorkletBridge(
        storageLocator: storage,
        backend: backend,
      );
      expect((await bridge.initialize()).isOk, isTrue);

      storage.blobs['loop_take.wav'] = _makeMinimalStereoWav(
        sampleRate: 48000,
        frames: 60000,
      );
      expect(
        (await bridge.syncActiveTakeRegions(const <ActiveTakePlaybackRegion>[
          ActiveTakePlaybackRegion(
            takeId: TakeId('take-loop'),
            partId: PartId('part-loop'),
            wavSha256: Sha256Digest('loop_take'),
            startSampleFrame: SampleFrame(0),
            durationFrames: 60000,
            gainDb: 0.0,
            pan: 0.0,
          ),
        ])).isOk,
        isTrue,
      );
      await pumpEventQueue();

      // Pre-loop playback: cursor at 0, loop region at [48000, 52096).
      backend.pushedTakeChunks.clear();
      expect(
        bridge
            .setLoopRegion(
              enabled: true,
              startFrame: const SampleFrame(48000),
              endFrame: const SampleFrame(52096),
            )
            .isOk,
        isTrue,
      );
      await pumpEventQueue();
      expect(backend.pushedTakeChunks, isNotEmpty);
      expect(backend.pushedTakeChunks.first.startSampleFrame, 0);

      // Short loop (< takePrefetchFrames = 16384): [0, 4096).
      expect(bridge.seekToSample(const SampleFrame(0)).isOk, isTrue);
      await pumpEventQueue();
      backend.pushedTakeChunks.clear();
      expect(
        bridge
            .setLoopRegion(
              enabled: true,
              startFrame: const SampleFrame(0),
              endFrame: const SampleFrame(4096),
            )
            .isOk,
        isTrue,
      );
      await pumpEventQueue();
      final shortLoopPushed = backend.pushedTakeChunks.fold<int>(
        0,
        (sum, c) => sum + c.frameCount,
      );
      expect(shortLoopPushed, 16384);
      expect(
        backend.pushedTakeChunks.every((c) => c.startSampleFrame == 0),
        isTrue,
      );

      // Moving from playhead 0 -> 3968 consumes 3968 frames -> tops up [0, 3968).
      backend.pushedTakeChunks.clear();
      backend.emitTelemetry(
        TelemetrySnapshot(
          playheadSampleFrame: const SampleFrame(3968),
          activeEpoch: bridge.currentEpoch,
          outputPeakL: 0.1,
          outputPeakR: 0.1,
          outputRmsL: 0.05,
          outputRmsR: 0.05,
          inputPeak: 0.0,
          inputRms: 0.0,
          isPlaying: true,
          isCapturing: false,
          hasEventQueueUnderrun: false,
          hasCaptureBufferOverflow: false,
          hasTakePlaybackUnderrun: false,
        ),
      );
      await pumpEventQueue();
      expect(
        backend.pushedTakeChunks
            .map((c) => (c.startSampleFrame, c.frameCount))
            .toList(),
        equals(<(int, int)>[(0, 3968)]),
      );

      // Wrapping 3968 -> 128 consumes 256 more frames across the loop boundary ->
      // decrements wrap lead count and pushes [3968, 4096) + [0, 128) cleanly.
      backend.pushedTakeChunks.clear();
      backend.emitTelemetry(
        TelemetrySnapshot(
          playheadSampleFrame: const SampleFrame(128),
          activeEpoch: bridge.currentEpoch,
          outputPeakL: 0.1,
          outputPeakR: 0.1,
          outputRmsL: 0.05,
          outputRmsR: 0.05,
          inputPeak: 0.0,
          inputRms: 0.0,
          isPlaying: true,
          isCapturing: false,
          hasEventQueueUnderrun: false,
          hasCaptureBufferOverflow: false,
          hasTakePlaybackUnderrun: false,
        ),
      );
      await pumpEventQueue();
      expect(
        backend.pushedTakeChunks
            .map((c) => (c.startSampleFrame, c.frameCount))
            .toList(),
        equals(<(int, int)>[(3968, 128), (0, 128)]),
      );

      await bridge.dispose();
    },
  );

  test(
    'prepareAndStartCapture rejects concurrent calls and mid-flight dispose fails closed',
    () async {
      final storage = _FakeStorageLocator();
      final backend = _FakeWebBackend();
      final bridge = WebAudioWorkletBridge(
        storageLocator: storage,
        backend: backend,
      );
      expect((await bridge.initialize()).isOk, isTrue);

      // Concurrent prepareAndStartCapture guard.
      final gate1 = Completer<Result<void>>();
      backend.prepareCaptureGate = gate1;
      final firstStartFuture = bridge.prepareAndStartCapture(
        const TakeId('take-a'),
      );
      final secondStartRes = await bridge.prepareAndStartCapture(
        const TakeId('take-b'),
      );
      expect(secondStartRes.isErr, isTrue);
      expect(
        (secondStartRes as Err<void>).error.code,
        MuseErrorCode.audioDeviceInitFailed,
      );
      expect(backend.prepareCaptureCalls, 1);
      gate1.complete(const Ok(null));
      expect((await firstStartFuture).isOk, isTrue);

      // Mid-flight dispose during stopAndFinalizeCapture fails closed without throwing.
      final stopGate = Completer<Result<WebCaptureFinalizedResult>>();
      backend.stopCaptureGate = stopGate;
      final stopFuture = bridge.stopAndFinalizeCapture(const TakeId('take-a'));
      await bridge.dispose();
      stopGate.complete(
        const Ok(
          WebCaptureFinalizedResult(
            durationFrames: 128,
            capturedSampleClock: 128,
            capturedPlayheadFrame: 0,
            hasOverflowed: false,
          ),
        ),
      );
      final stopRes = await stopFuture;
      expect(stopRes.isErr, isTrue);
      expect(
        (stopRes as Err<RecordingCaptureReceipt>).error.code,
        MuseErrorCode.casPromotionFailed,
      );

      // Mid-flight dispose during prepareAndStartCapture fails closed without throwing.
      final backend2 = _FakeWebBackend();
      final bridge2 = WebAudioWorkletBridge(
        storageLocator: storage,
        backend: backend2,
      );
      expect((await bridge2.initialize()).isOk, isTrue);
      final startGate2 = Completer<Result<void>>();
      backend2.prepareCaptureGate = startGate2;
      final startFuture2 = bridge2.prepareAndStartCapture(
        const TakeId('take-c'),
      );
      await bridge2.dispose();
      startGate2.complete(const Ok(null));
      final startRes2 = await startFuture2;
      expect(startRes2.isErr, isTrue);
      expect(
        (startRes2 as Err<void>).error.code,
        MuseErrorCode.audioDeviceInitFailed,
      );
    },
  );

  test(
    'scheduleEvents accepts immediateDispatchFrame, validates MIDI errors, maps zero-velocity audition to noteOff, and surfaces async Worklet push errors',
    () async {
      final storage = _FakeStorageLocator();
      final backend = _FakeWebBackend();
      final bridge = WebAudioWorkletBridge(
        storageLocator: storage,
        backend: backend,
      );
      expect((await bridge.initialize()).isOk, isTrue);

      // immediateDispatchFrame (-1) must be accepted without emitting a -1 watermark.
      final immediateOnly = bridge.scheduleEvents(<ScheduledMidiEvent>[
        ScheduledMidiEvent(
          epoch: bridge.currentEpoch,
          targetSampleFrame: const SampleFrame(
            MuseConstants.immediateDispatchFrame,
          ),
          type: MuseConstants.midiEventNoteOn,
          channel: 0,
          data1: 60,
          data2: 100,
        ),
      ]);
      expect(immediateOnly, isA<Ok<int>>());
      expect((immediateOnly as Ok<int>).value, 1);
      expect(backend.pushedEvents.length, 1);
      expect(backend.pushedMutations, isEmpty);

      // Invalid MIDI parameters all map to invalidMidiChannelOrPitch.
      final badVel = bridge.scheduleEvents(<ScheduledMidiEvent>[
        ScheduledMidiEvent(
          epoch: bridge.currentEpoch,
          targetSampleFrame: const SampleFrame(128),
          type: MuseConstants.midiEventNoteOn,
          channel: 0,
          data1: 60,
          data2: 128,
        ),
      ]);
      expect(
        (badVel as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      final badBend = bridge.scheduleEvents(<ScheduledMidiEvent>[
        ScheduledMidiEvent(
          epoch: bridge.currentEpoch,
          targetSampleFrame: const SampleFrame(128),
          type: MuseConstants.midiEventPitchBend,
          channel: 0,
          data1: 0,
          data2: 0,
          pitchBend: 8192,
        ),
      ]);
      expect(
        (badBend as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      final badEpoch = bridge.scheduleEvents(<ScheduledMidiEvent>[
        const ScheduledMidiEvent(
          epoch: EpochId(-1),
          targetSampleFrame: SampleFrame(128),
          type: MuseConstants.midiEventNoteOn,
          channel: 0,
          data1: 60,
          data2: 100,
        ),
      ]);
      expect(
        (badEpoch as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      final badFrame = bridge.scheduleEvents(<ScheduledMidiEvent>[
        ScheduledMidiEvent(
          epoch: bridge.currentEpoch,
          targetSampleFrame: const SampleFrame(-2),
          type: MuseConstants.midiEventNoteOn,
          channel: 0,
          data1: 60,
          data2: 100,
        ),
      ]);
      expect(
        (badFrame as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      // Empty batch with scheduledUpToFrame pushes MUT_SET_SCHEDULED_WATERMARK (11) without pushEvents.
      backend.pushedEvents.clear();
      backend.pushedMutations.clear();
      backend.pushedMutationDetails.clear();
      final emptyWatermarkRes = bridge.scheduleEvents(
        const <ScheduledMidiEvent>[],
        scheduledUpToFrame: const SampleFrame(9600),
      );
      expect(emptyWatermarkRes, isA<Ok<int>>());
      expect((emptyWatermarkRes as Ok<int>).value, 0);
      expect(backend.pushedEvents, isEmpty);
      expect(backend.pushedMutations, <int>[11]);
      expect(backend.pushedMutationDetails.single.sampleFrameA, 9600);

      // Non-empty batch with scheduledUpToFrame uses scheduledUpToFrame instead of max event frame.
      backend.pushedEvents.clear();
      backend.pushedMutations.clear();
      backend.pushedMutationDetails.clear();
      final horizonBatchRes = bridge.scheduleEvents(
        <ScheduledMidiEvent>[
          ScheduledMidiEvent(
            epoch: bridge.currentEpoch,
            targetSampleFrame: const SampleFrame(128),
            type: MuseConstants.midiEventNoteOn,
            channel: 0,
            data1: 60,
            data2: 100,
          ),
        ],
        scheduledUpToFrame: const SampleFrame(12000),
      );
      expect((horizonBatchRes as Ok<int>).value, 1);
      expect(backend.pushedEvents.length, 1);
      expect(backend.pushedMutationDetails.single.mutationType, 11);
      expect(backend.pushedMutationDetails.single.sampleFrameA, 12000);

      // Negative scheduledUpToFrame fails closed.
      final badWatermarkRes = bridge.scheduleEvents(
        const <ScheduledMidiEvent>[],
        scheduledUpToFrame: const SampleFrame(-1),
      );
      expect(
        (badWatermarkRes as Err<int>).error.code,
        MuseErrorCode.invalidMidiChannelOrPitch,
      );

      // triggerLiveAuditionNote maps velocity == 0 with isNoteOn: true to midiEventNoteOff.
      backend.pushedEvents.clear();
      expect(
        bridge
            .triggerLiveAuditionNote(
              midiChannel: 0,
              pitchMidi: 64,
              velocity: 0,
              isNoteOn: true,
            )
            .isOk,
        isTrue,
      );
      expect(backend.pushedEvents.single.type, MuseConstants.midiEventNoteOff);
      expect(backend.pushedEvents.single.data2, 0);

      // Async Worklet event queue overflow is surfaced on next event call, then clears.
      backend.emitAsyncError(
        const MuseError(
          MuseErrorCode.eventQueueOverflow,
          'Worklet event ring full.',
        ),
      );
      final overflowRes = bridge.triggerLiveAuditionNote(
        midiChannel: 0,
        pitchMidi: 60,
        velocity: 96,
        isNoteOn: true,
      );
      expect(overflowRes.isErr, isTrue);
      expect(
        (overflowRes as Err<void>).error.code,
        MuseErrorCode.eventQueueOverflow,
      );
      expect(
        bridge
            .triggerLiveAuditionNote(
              midiChannel: 0,
              pitchMidi: 60,
              velocity: 96,
              isNoteOn: true,
            )
            .isOk,
        isTrue,
      );

      // Async fatal Worklet mutation failure stays failed closed on subsequent mutations.
      backend.emitAsyncError(
        const MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'AudioWorklet engine is not ready.',
        ),
      );
      final playErr = bridge.play();
      expect(playErr.isErr, isTrue);
      expect(
        (playErr as Err<void>).error.code,
        MuseErrorCode.audioDeviceInitFailed,
      );

      await bridge.dispose();
    },
  );
}
