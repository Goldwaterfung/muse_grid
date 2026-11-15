/// Web AudioWorklet + Emscripten Wasm + OPFS Worker implementation of all 5
/// Middle Bridge audio contracts (`flutter build web --wasm` compatible).
library;

import 'dart:async';
import 'dart:collection';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:web/web.dart' as web;

import '../contracts/audio_bridge_contracts.dart';
import '../contracts/engine_constants.dart';
import '../contracts/ids_and_units.dart';
import '../contracts/result.dart';
import 'web_audio_protocol.dart';

enum _WebLifecyclePhase {
  uninitialized,
  initializing,
  ready,
  disposing,
  disposed,
}

/// Abstract host transport boundary separating browser `package:web` AudioWorklet
/// + OPFS Worker APIs from testable protocol coordination logic.
abstract interface class WebAudioHostBackend {
  bool get isSecureContext;

  Future<Result<AudioHardwareInfo>> startSession({
    required void Function(List<TelemetrySnapshot> frames) onTelemetryBatch,
    required void Function() onUnexpectedDisconnect,
    void Function(MuseError error)? onAsyncError,
  });

  Future<Result<LoadedSoundFontDescriptor>> loadSf2Bytes({
    required Sha256Digest sha256,
    required Uint8List bytes,
  });

  Future<Result<void>> unloadSf2(int sfHandle);

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
  });

  Result<int> pushEvents(List<ScheduledMidiEvent> events);

  Future<Result<void>> clearActiveTakes();

  Future<Result<void>> registerActiveTake({
    required String takeId,
    required String casPath,
    required int startSampleFrame,
    required int durationFrames,
    required double gainDb,
    required double pan,
  });

  Future<Result<int>> pushTakePcm({
    required int epoch,
    required int startSampleFrame,
    required Float32List interleavedStereoF32,
    required int frameCount,
  });

  Future<Result<void>> prepareAndStartCapture({
    required String stagingPath,
    required AudioHardwareInfo hardwareInfo,
  });

  Future<Result<WebCaptureFinalizedResult>> stopAndFinalizeCapture({
    required String stagingPath,
  });

  Future<Result<String>> computeOpfsFileSha256(String stagingPath);

  Future<void> dispose();
}

/// Finalized capture timing + OPFS file stats returned by [WebAudioHostBackend].
final class WebCaptureFinalizedResult {
  final int durationFrames;
  final int capturedSampleClock;
  final int capturedPlayheadFrame;
  final bool hasOverflowed;

  const WebCaptureFinalizedResult({
    required this.durationFrames,
    required this.capturedSampleClock,
    required this.capturedPlayheadFrame,
    required this.hasOverflowed,
  });
}

/// Web `AudioWorkletNode` + OPFS dedicated Worker audio bridge.
final class WebAudioWorkletBridge
    implements
        IAudioLifecycleBridge,
        ITransportBridge,
        ISynthEventBridge,
        IRecordingBridge,
        ITelemetryBridge {
  static const int _initialEpochValue = 0;
  static const int _mutSetPlaying = 1;
  static const int _mutSeekSample = 2;
  static const int _mutSetLoopRegion = 3;
  static const int _mutFlushAndAdvanceEpoch = 4;
  static const int _mutAssignChannelPatch = 5;
  static const int _mutSetChannelMix = 6;
  static const int _mutAllNotesOffChannel = 7;
  static const int _mutSetMonitorGain = 8;
  static const int _mutSetScheduledWatermark = 11;
  static const int _takeStreamChunkFrames = 4096;
  static const int _stereoChannels = 2;
  static const String _sf2Extension = 'sf2';
  static const String _wavExtension = 'wav';

  final IInternalStorageLocator _storageLocator;
  final WebAudioHostBackend _backend;

  _WebLifecyclePhase _phase = _WebLifecyclePhase.uninitialized;
  AudioHardwareInfo? _hardwareInfo;
  EpochId _currentEpoch = const EpochId(_initialEpochValue);
  bool _isPlaying = false;
  bool _isCapturing = false;
  bool _captureTransitioning = false;
  TakeId? _activeCaptureTakeId;
  String? _activeCaptureStagingPath;

  bool _loopEnabled = false;
  int _loopStartFrame = 0;
  int _loopEndFrame = 0;

  TelemetrySnapshot? _latestSnapshot;
  final Queue<TelemetrySnapshot> _telemetryQueue = Queue<TelemetrySnapshot>();

  List<_PreparedWebTake> _preparedTakes = const <_PreparedWebTake>[];
  int _prefetchCursorFrame = 0;
  int _loopWrapLeadCount = 0;
  int _lastObservedTelemetryPlayhead = 0;
  int _prefetchGeneration = 0;
  bool _prefetchPumping = false;
  bool _prefetchNeedsAnotherPass = false;
  MuseError? _pendingEventQueueError;
  MuseError? _pendingMutationError;

  /// Creates a Web `AudioWorklet` + OPFS Worker bridge bound to `_storageLocator`.
  WebAudioWorkletBridge({
    required this._storageLocator,
    WebAudioHostBackend? backend,
  }) : _backend = backend ?? _BrowserWebAudioHostBackend();

  // ---------------------------------------------------------------------------
  // IAudioLifecycleBridge
  // ---------------------------------------------------------------------------

  @override
  AudioHardwareInfo get currentHardwareInfo {
    final info = _hardwareInfo;
    if (_phase != _WebLifecyclePhase.ready || info == null) {
      throw StateError('Web audio engine is not initialized.');
    }
    return info;
  }

  @override
  Future<Result<AudioHardwareInfo>> initialize() async {
    if (_phase != _WebLifecyclePhase.uninitialized) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Web audio engine initialize() called in an invalid lifecycle state.',
        ),
      );
    }
    if (!_backend.isSecureContext) {
      return const Err(
        MuseError(
          MuseErrorCode.webAudioUserGestureRequired,
          'Web AudioWorklet requires HTTPS or localhost secure context.',
        ),
      );
    }

    _phase = _WebLifecyclePhase.initializing;
    _pendingEventQueueError = null;
    _pendingMutationError = null;
    final startResult = await _backend.startSession(
      onTelemetryBatch: _handleTelemetryBatch,
      onUnexpectedDisconnect: _handleUnexpectedBackendDisconnect,
      onAsyncError: _handleAsyncBackendError,
    );
    switch (startResult) {
      case Err<AudioHardwareInfo>(:final error):
        _phase = _WebLifecyclePhase.uninitialized;
        return Err(error);
      case Ok<AudioHardwareInfo>(:final value):
        if (_phase != _WebLifecyclePhase.initializing) {
          await _backend.dispose();
          return const Err(
            MuseError(
              MuseErrorCode.audioDeviceInitFailed,
              'Web audio engine was disposed during initialization.',
            ),
          );
        }
        _hardwareInfo = value;
        _phase = _WebLifecyclePhase.ready;
        return Ok(value);
    }
  }

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  }) async {
    final readyCheck = WebBridgeValidator.checkInitialized<
      LoadedSoundFontDescriptor
    >(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.soundFontLoadFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (sha256.value.isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.casBlobMissing,
          'SoundFont SHA-256 digest must not be empty.',
        ),
      );
    }

    final stoppedCheck = WebBridgeValidator.checkNotPlayingForWebSf2Load<
      LoadedSoundFontDescriptor
    >(isPlaying: _isPlaying);
    if (stoppedCheck != null) {
      return stoppedCheck;
    }

    final readResult = await _storageLocator.readCasBlobBytes(
      sha256,
      ext: _sf2Extension,
    );
    final List<int> rawBytes;
    switch (readResult) {
      case Err<List<int>>(:final error):
        return Err(error);
      case Ok<List<int>>(:final value):
        rawBytes = value;
    }

    if (rawBytes.isEmpty) {
      return Err(
        MuseError(
          MuseErrorCode.casBlobMissing,
          'SoundFont CAS blob is empty for ${sha256.value}.',
        ),
      );
    }

    final sizeCheck = WebBridgeValidator.checkWebSoundFontSize<
      LoadedSoundFontDescriptor
    >(rawBytes.length);
    if (sizeCheck != null) {
      return sizeCheck;
    }

    if (_phase != _WebLifecyclePhase.ready) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'Web audio engine was disposed before SoundFont bytes loaded.',
        ),
      );
    }
    final recheckStopped = WebBridgeValidator.checkNotPlayingForWebSf2Load<
      LoadedSoundFontDescriptor
    >(isPlaying: _isPlaying);
    if (recheckStopped != null) {
      return recheckStopped;
    }

    final transferBytes = Uint8List.fromList(rawBytes);
    final res = await _backend.loadSf2Bytes(
      sha256: sha256,
      bytes: transferBytes,
    );
    if (_phase != _WebLifecyclePhase.ready) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'Web audio engine was disposed while loading SoundFont.',
        ),
      );
    }
    return res;
  }

  @override
  Future<Result<void>> unloadSoundFont(SoundFontHandle handle) async {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.soundFontLoadFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (handle.value <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'SoundFont handle must be positive.',
        ),
      );
    }
    final res = await _backend.unloadSf2(handle.value);
    if (_phase != _WebLifecyclePhase.ready) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'Web audio engine was disposed while unloading SoundFont.',
        ),
      );
    }
    return res;
  }

  @override
  Future<void> dispose() async {
    if (_phase == _WebLifecyclePhase.disposed ||
        _phase == _WebLifecyclePhase.uninitialized) {
      _phase = _WebLifecyclePhase.disposed;
      return;
    }
    _phase = _WebLifecyclePhase.disposing;
    _isPlaying = false;
    _isCapturing = false;
    _captureTransitioning = false;
    _activeCaptureTakeId = null;
    _activeCaptureStagingPath = null;
    _preparedTakes = const <_PreparedWebTake>[];
    _prefetchGeneration++;
    _prefetchCursorFrame = 0;
    _loopWrapLeadCount = 0;
    _lastObservedTelemetryPlayhead = 0;
    _telemetryQueue.clear();
    _latestSnapshot = null;
    _hardwareInfo = null;
    _pendingEventQueueError = null;
    _pendingMutationError = null;
    await _backend.dispose();
    _phase = _WebLifecyclePhase.disposed;
  }

  // ---------------------------------------------------------------------------
  // ITransportBridge
  // ---------------------------------------------------------------------------

  @override
  Result<void> play() {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final res = _pushBackendMutation(mutationType: _mutSetPlaying, flagA: 1);
    if (res.isOk) {
      _isPlaying = true;
      if (_preparedTakes.isNotEmpty) {
        unawaited(_pumpActiveTakePrefetch());
      }
    }
    return res;
  }

  @override
  Result<void> pause() {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final res = _pushBackendMutation(mutationType: _mutSetPlaying, flagA: 0);
    if (res.isOk) {
      _isPlaying = false;
    }
    return res;
  }

  @override
  Result<void> stop() {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final pauseRes = _pushBackendMutation(
      mutationType: _mutSetPlaying,
      flagA: 0,
    );
    if (pauseRes.isErr) {
      return pauseRes;
    }

    final nextEpoch = EpochId(_currentEpoch.value + 1);
    final flushRes = _pushBackendMutation(
      mutationType: _mutFlushAndAdvanceEpoch,
      targetEpoch: nextEpoch.value,
    );
    if (flushRes.isErr) {
      return flushRes;
    }
    final seekRes = _pushBackendMutation(
      mutationType: _mutSeekSample,
      targetEpoch: nextEpoch.value,
      sampleFrameA: 0,
    );
    if (seekRes.isErr) {
      return seekRes;
    }

    _isPlaying = false;
    _currentEpoch = nextEpoch;
    _pendingEventQueueError = null;
    _lastObservedTelemetryPlayhead = 0;
    _resetTakePrefetchCursor(0);
    return const Ok(null);
  }

  @override
  Result<EpochId> seekToSample(SampleFrame targetFrame) {
    final readyCheck = WebBridgeValidator.checkInitialized<EpochId>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (targetFrame.value < 0) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Seek target sample frame must be non-negative.',
        ),
      );
    }

    final nextEpoch = EpochId(_currentEpoch.value + 1);
    final seekRes = _pushBackendMutation(
      mutationType: _mutSeekSample,
      targetEpoch: nextEpoch.value,
      sampleFrameA: targetFrame.value,
    );
    if (seekRes case Err<void>(:final error)) {
      return Err(error);
    }

    _currentEpoch = nextEpoch;
    _pendingEventQueueError = null;
    _lastObservedTelemetryPlayhead = targetFrame.value;
    _resetTakePrefetchCursor(targetFrame.value);
    if (_preparedTakes.isNotEmpty) {
      unawaited(_pumpActiveTakePrefetch());
    }
    return Ok(nextEpoch);
  }

  @override
  Result<void> setLoopRegion({
    required bool enabled,
    required SampleFrame startFrame,
    required SampleFrame endFrame,
  }) {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final loopCheck = WebBridgeValidator.checkLoopRegion<void>(
      enabled: enabled,
      startFrame: startFrame.value,
      endFrame: endFrame.value,
    );
    if (loopCheck != null) {
      return loopCheck;
    }

    final res = _pushBackendMutation(
      mutationType: _mutSetLoopRegion,
      flagA: enabled ? 1 : 0,
      sampleFrameA: startFrame.value,
      sampleFrameB: endFrame.value,
    );
    if (res.isOk) {
      _loopEnabled = enabled;
      _loopStartFrame = startFrame.value;
      _loopEndFrame = endFrame.value;
      _resetTakePrefetchCursor(_lastObservedTelemetryPlayhead);
      if (_preparedTakes.isNotEmpty) {
        unawaited(_pumpActiveTakePrefetch());
      }
    }
    return res;
  }

  @override
  Future<Result<void>> syncActiveTakeRegions(
    List<ActiveTakePlaybackRegion> regions,
  ) async {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.takeLoadFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final countCheck = WebBridgeValidator.checkTakeRegionCount<void>(
      regions.length,
    );
    if (countCheck != null) {
      return countCheck;
    }

    final targetSampleRate = currentHardwareInfo.sampleRate;
    final prepared = <_PreparedWebTake>[];
    for (final region in regions) {
      if (region.takeId.value.isEmpty ||
          region.wavSha256.value.isEmpty ||
          region.startSampleFrame.value < 0 ||
          region.durationFrames <= 0 ||
          !region.gainDb.isFinite ||
          !region.pan.isFinite) {
        return const Err(
          MuseError(
            MuseErrorCode.takeLoadFailed,
            'ActiveTakePlaybackRegion contains invalid ID, frame range, or gain/pan.',
          ),
        );
      }

      final readRes = await _storageLocator.readCasBlobBytes(
        region.wavSha256,
        ext: _wavExtension,
      );
      final List<int> rawBytes;
      switch (readRes) {
        case Err<List<int>>(:final error):
          return Err(
            MuseError(
              MuseErrorCode.casBlobMissing,
              'Take WAV CAS blob missing for ${region.wavSha256.value}: ${error.message}',
              cause: error,
            ),
          );
        case Ok<List<int>>(:final value):
          rawBytes = value;
      }

      if (rawBytes.isEmpty) {
        return Err(
          MuseError(
            MuseErrorCode.casBlobMissing,
            'Take WAV CAS blob is empty for ${region.wavSha256.value}.',
          ),
        );
      }

      final decodedRes = RiffWavCodec.decodeWavBytes(
        rawBytes is Uint8List ? rawBytes : Uint8List.fromList(rawBytes),
      );
      final DecodedWavPcm decoded;
      switch (decodedRes) {
        case Err<DecodedWavPcm>(:final error):
          return Err(error);
        case Ok<DecodedWavPcm>(:final value):
          decoded = value;
      }

      final resampledStereo = RiffWavCodec.resampleAndMixTakeToStereoF32(
        pcm: decoded,
        targetSampleRate: targetSampleRate,
        gainDb: region.gainDb,
        pan: region.pan,
      );
      final decodedFrames = resampledStereo.length ~/ _stereoChannels;
      final clampedDuration = math.min(region.durationFrames, decodedFrames);
      if (clampedDuration <= 0) {
        return const Err(
          MuseError(
            MuseErrorCode.takeLoadFailed,
            'Decoded take WAV contains zero playable frames.',
          ),
        );
      }

      prepared.add(
        _PreparedWebTake(
          takeId: region.takeId.value,
          casPath: region.wavSha256.value,
          startSampleFrame: region.startSampleFrame.value,
          durationFrames: clampedDuration,
          gainDb: region.gainDb,
          pan: region.pan,
          interleavedStereoF32: resampledStereo,
        ),
      );
    }

    if (_phase != _WebLifecyclePhase.ready) {
      return const Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Web audio engine disposed while preparing takes.',
        ),
      );
    }

    final clearRes = await _backend.clearActiveTakes();
    if (_phase != _WebLifecyclePhase.ready) {
      return const Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Web audio engine disposed while clearing takes.',
        ),
      );
    }
    if (clearRes.isErr) {
      return clearRes;
    }

    for (final take in prepared) {
      final regRes = await _backend.registerActiveTake(
        takeId: take.takeId,
        casPath: take.casPath,
        startSampleFrame: take.startSampleFrame,
        durationFrames: take.durationFrames,
        gainDb: take.gainDb,
        pan: take.pan,
      );
      if (_phase != _WebLifecyclePhase.ready) {
        return const Err(
          MuseError(
            MuseErrorCode.takeLoadFailed,
            'Web audio engine disposed while registering takes.',
          ),
        );
      }
      if (regRes.isErr) {
        await _backend.clearActiveTakes();
        return regRes;
      }
    }

    _preparedTakes = List<_PreparedWebTake>.unmodifiable(prepared);
    _resetTakePrefetchCursor(_lastObservedTelemetryPlayhead);
    if (_preparedTakes.isNotEmpty) {
      await _pumpActiveTakePrefetch();
    }
    return const Ok(null);
  }

  // ---------------------------------------------------------------------------
  // ISynthEventBridge
  // ---------------------------------------------------------------------------

  @override
  EpochId get currentEpoch => _currentEpoch;

  @override
  Result<EpochId> flushAndAdvanceEpoch() {
    final readyCheck = WebBridgeValidator.checkInitialized<EpochId>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }

    final nextEpoch = EpochId(_currentEpoch.value + 1);
    final res = _pushBackendMutation(
      mutationType: _mutFlushAndAdvanceEpoch,
      targetEpoch: nextEpoch.value,
    );
    if (res case Err<void>(:final error)) {
      return Err(error);
    }
    _currentEpoch = nextEpoch;
    _pendingEventQueueError = null;
    _resetTakePrefetchCursor(_lastObservedTelemetryPlayhead);
    if (_preparedTakes.isNotEmpty) {
      unawaited(_pumpActiveTakePrefetch());
    }
    return Ok(nextEpoch);
  }

  @override
  Result<int> scheduleEvents(
    List<ScheduledMidiEvent> events, {
    SampleFrame? scheduledUpToFrame,
  }) {
    final readyCheck = WebBridgeValidator.checkInitialized<int>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.eventQueueOverflow,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (scheduledUpToFrame != null && scheduledUpToFrame.value < 0) {
      return Err(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'Scheduled watermark frame (${scheduledUpToFrame.value}) must be non-negative.',
        ),
      );
    }
    if (events.isEmpty) {
      if (scheduledUpToFrame == null) {
        return const Ok(0);
      }
      final pendingEventErr = _pendingEventQueueError;
      if (pendingEventErr != null) {
        _pendingEventQueueError = null;
        return Err(pendingEventErr);
      }
      final wmRes = _pushBackendMutation(
        mutationType: _mutSetScheduledWatermark,
        targetEpoch: _currentEpoch.value,
        sampleFrameA: scheduledUpToFrame.value,
      );
      if (wmRes case Err<void>(:final error)) {
        return Err(error);
      }
      return const Ok(0);
    }

    int? maxCurrentEpochFrame;
    for (final evt in events) {
      final typeCheck = WebBridgeValidator.checkMidiEventType<int>(evt.type);
      if (typeCheck != null) {
        return typeCheck;
      }
      final epochCheck = WebBridgeValidator.checkEventEpoch<int>(evt.epoch.value);
      if (epochCheck != null) {
        return epochCheck;
      }
      final frameCheck = WebBridgeValidator.checkScheduledSampleFrame<int>(
        evt.targetSampleFrame.value,
      );
      if (frameCheck != null) {
        return frameCheck;
      }
      final chCheck = WebBridgeValidator.checkMidiChannel<int>(evt.channel);
      if (chCheck != null) {
        return chCheck;
      }
      final keyCheck = WebBridgeValidator.checkSevenBitVelocityOrCc<int>(
        evt.data1,
        'MIDI key/CC',
      );
      if (keyCheck != null) {
        return keyCheck;
      }
      final valCheck = WebBridgeValidator.checkSevenBitVelocityOrCc<int>(
        evt.data2,
        'MIDI velocity/value',
      );
      if (valCheck != null) {
        return valCheck;
      }
      final bendCheck = WebBridgeValidator.checkPitchBend<int>(evt.pitchBend);
      if (bendCheck != null) {
        return bendCheck;
      }
      if (evt.epoch.value == _currentEpoch.value &&
          evt.targetSampleFrame.value != MuseConstants.immediateDispatchFrame &&
          (maxCurrentEpochFrame == null ||
              evt.targetSampleFrame.value > maxCurrentEpochFrame)) {
        maxCurrentEpochFrame = evt.targetSampleFrame.value;
      }
    }

    final pushRes = _pushBackendEvents(events);
    if (pushRes case Err<int>(:final error)) {
      return Err(error);
    }

    final watermarkFrame = scheduledUpToFrame?.value ?? maxCurrentEpochFrame;
    if (watermarkFrame != null) {
      final wmRes = _pushBackendMutation(
        mutationType: _mutSetScheduledWatermark,
        targetEpoch: _currentEpoch.value,
        sampleFrameA: watermarkFrame,
      );
      if (wmRes case Err<void>(:final error)) {
        return Err(error);
      }
    }
    return pushRes;
  }

  @override
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  }) {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.soundFontLoadFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final chCheck = WebBridgeValidator.checkMidiChannel<void>(midiChannel);
    if (chCheck != null) {
      return chCheck;
    }
    if (sfHandle.value <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'SoundFont handle must be positive.',
        ),
      );
    }
    final bpCheck = WebBridgeValidator.checkBankAndProgram<void>(
      bankNum,
      programNum,
    );
    if (bpCheck != null) {
      return bpCheck;
    }
    return _pushBackendMutation(
      mutationType: _mutAssignChannelPatch,
      channel: midiChannel,
      intParamA: sfHandle.value,
      intParamB: bankNum,
      intParamC: programNum,
    );
  }

  @override
  Result<void> setChannelMix({
    required int midiChannel,
    required double gainDb,
    required double pan,
  }) {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final chCheck = WebBridgeValidator.checkMidiChannel<void>(midiChannel);
    if (chCheck != null) {
      return chCheck;
    }
    if (!gainDb.isFinite || !pan.isFinite) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Channel mix gainDb and pan must be finite.',
        ),
      );
    }
    return _pushBackendMutation(
      mutationType: _mutSetChannelMix,
      channel: midiChannel,
      floatParamA: gainDb,
      floatParamB: pan,
    );
  }

  @override
  Result<void> silenceChannel(int midiChannel) {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final chCheck = WebBridgeValidator.checkMidiChannel<void>(midiChannel);
    if (chCheck != null) {
      return chCheck;
    }
    return _pushBackendMutation(
      mutationType: _mutAllNotesOffChannel,
      channel: midiChannel,
    );
  }

  @override
  Result<void> triggerLiveAuditionNote({
    required int midiChannel,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.eventQueueOverflow,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    final chCheck = WebBridgeValidator.checkMidiChannel<void>(midiChannel);
    if (chCheck != null) {
      return chCheck;
    }
    final pitchCheck = WebBridgeValidator.checkPitch<void>(pitchMidi);
    if (pitchCheck != null) {
      return pitchCheck;
    }
    final velCheck = WebBridgeValidator.checkSevenBitVelocityOrCc<void>(
      velocity,
      'MIDI velocity',
    );
    if (velCheck != null) {
      return velCheck;
    }

    final evt = ScheduledMidiEvent(
      epoch: _currentEpoch,
      targetSampleFrame: const SampleFrame(MuseConstants.immediateDispatchFrame),
      type: (isNoteOn && velocity > 0)
          ? MuseConstants.midiEventNoteOn
          : MuseConstants.midiEventNoteOff,
      channel: midiChannel,
      data1: pitchMidi,
      data2: isNoteOn ? velocity : 0,
      pitchBend: MuseConstants.neutralPitchBend,
    );
    final res = _pushBackendEvents(<ScheduledMidiEvent>[evt]);
    return switch (res) {
      Err<int>(:final error) => Err(error),
      Ok<int>() => const Ok(null),
    };
  }

  // ---------------------------------------------------------------------------
  // IRecordingBridge
  // ---------------------------------------------------------------------------

  @override
  Result<void> setMonitorGain(double gainLinear) {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (!gainLinear.isFinite || gainLinear < 0.0) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Monitor linear gain must be finite and non-negative.',
        ),
      );
    }
    return _pushBackendMutation(
      mutationType: _mutSetMonitorGain,
      floatParamA: gainLinear,
    );
  }

  @override
  Future<Result<void>> prepareAndStartCapture(TakeId takeId) async {
    final readyCheck = WebBridgeValidator.checkInitialized<void>(
      isInitialized: _phase == _WebLifecyclePhase.ready,
      errorCode: MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (!_backend.isSecureContext) {
      return const Err(
        MuseError(
          MuseErrorCode.webAudioUserGestureRequired,
          'Microphone capture requires a secure HTTPS or localhost origin.',
        ),
      );
    }
    if (_isCapturing || _captureTransitioning) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Recording capture is already active or transitioning.',
        ),
      );
    }
    if (takeId.value.isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'TakeId must not be empty when starting capture.',
        ),
      );
    }

    final stagingPath = _storageLocator.resolveRecordingStagingPath(takeId);
    if (stagingPath.isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Resolved OPFS recording staging path is empty.',
        ),
      );
    }

    _captureTransitioning = true;
    try {
      final startRes = await _backend.prepareAndStartCapture(
        stagingPath: stagingPath,
        hardwareInfo: currentHardwareInfo,
      );
      if (_phase != _WebLifecyclePhase.ready) {
        return const Err(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Web audio engine was disposed while starting capture.',
          ),
        );
      }
      if (startRes.isOk) {
        _isCapturing = true;
        _activeCaptureTakeId = takeId;
        _activeCaptureStagingPath = stagingPath;
      }
      return startRes;
    } finally {
      _captureTransitioning = false;
    }
  }

  @override
  Future<Result<RecordingCaptureReceipt>> stopAndFinalizeCapture(
    TakeId takeId,
  ) async {
    final readyCheck =
        WebBridgeValidator.checkInitialized<RecordingCaptureReceipt>(
          isInitialized: _phase == _WebLifecyclePhase.ready,
          errorCode: MuseErrorCode.casPromotionFailed,
        );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (_captureTransitioning ||
        !_isCapturing ||
        _activeCaptureTakeId != takeId ||
        _activeCaptureStagingPath == null) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'No active Web capture matches requested TakeId.',
        ),
      );
    }

    final stagingPath = _activeCaptureStagingPath!;
    final hw = currentHardwareInfo;

    _captureTransitioning = true;
    _isCapturing = false;
    _activeCaptureTakeId = null;
    _activeCaptureStagingPath = null;

    try {
      final finalizedRes = await _backend.stopAndFinalizeCapture(
        stagingPath: stagingPath,
      );
      if (_phase != _WebLifecyclePhase.ready) {
        return const Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'Web audio engine was disposed while finalizing capture.',
          ),
        );
      }
      final WebCaptureFinalizedResult finalized;
      switch (finalizedRes) {
        case Err<WebCaptureFinalizedResult>(:final error):
          return Err(error);
        case Ok<WebCaptureFinalizedResult>(:final value):
          finalized = value;
      }

      if (finalized.hasOverflowed) {
        return const Err(
          MuseError(
            MuseErrorCode.captureBufferOverflow,
            'Web CaptureRingBuffer overflowed before OPFS worker drained frames.',
          ),
        );
      }

      final shaRes = await _backend.computeOpfsFileSha256(stagingPath);
      if (_phase != _WebLifecyclePhase.ready) {
        return const Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'Web audio engine was disposed while verifying capture SHA-256.',
          ),
        );
      }
      final String shaHex;
      switch (shaRes) {
        case Err<String>(:final error):
          return Err(error);
        case Ok<String>(:final value):
          shaHex = value;
      }

      return Ok(
        RecordingCaptureReceipt(
          takeId: takeId,
          stagingPath: stagingPath,
          sha256: Sha256Digest(shaHex),
          capturedSampleClock: SampleFrame(finalized.capturedSampleClock),
          capturedPlayheadFrame: SampleFrame(finalized.capturedPlayheadFrame),
          durationFrames: finalized.durationFrames,
          sampleRate: hw.sampleRate,
          channelCount: hw.inputChannels,
          outputBufferFrames: hw.outputBufferFrames,
          inputBufferFrames: hw.inputBufferFrames,
        ),
      );
    } finally {
      _captureTransitioning = false;
    }
  }

  // ---------------------------------------------------------------------------
  // ITelemetryBridge
  // ---------------------------------------------------------------------------

  @override
  TelemetrySnapshot? get latestSnapshot => _latestSnapshot;

  @override
  List<TelemetrySnapshot> drainTelemetry({
    int maxFrames = MuseConstants.maxTelemetryDrainFrames,
  }) {
    if (maxFrames <= 0 || _telemetryQueue.isEmpty) {
      return const <TelemetrySnapshot>[];
    }
    final takeCount = math.min(maxFrames, _telemetryQueue.length);
    final drained = List<TelemetrySnapshot>.generate(
      takeCount,
      (_) => _telemetryQueue.removeFirst(),
      growable: false,
    );
    return drained;
  }

  // ---------------------------------------------------------------------------
  // Internal Telemetry & Take Prefetch Streaming
  // ---------------------------------------------------------------------------

  void _handleTelemetryBatch(List<TelemetrySnapshot> frames) {
    if (_phase != _WebLifecyclePhase.ready || frames.isEmpty) {
      return;
    }
    var sawActiveEpochFrame = false;
    var jumpedBackwardOutsideLoop = false;
    final loopActive =
        _loopEnabled && !_isCapturing && _loopEndFrame > _loopStartFrame;

    for (final frame in frames) {
      _latestSnapshot = frame;
      while (_telemetryQueue.length >= MuseConstants.maxTelemetryDrainFrames) {
        _telemetryQueue.removeFirst();
      }
      _telemetryQueue.addLast(frame);

      // Drop stale-epoch playhead updates so pre-seek/stop telemetry cannot
      // pull _lastObservedTelemetryPlayhead or trigger spurious cursor resets.
      if (frame.activeEpoch != _currentEpoch) {
        continue;
      }

      sawActiveEpochFrame = true;
      final framePos = frame.playheadSampleFrame.value;
      if (framePos < _lastObservedTelemetryPlayhead) {
        final isLoopWrap =
            loopActive &&
            _lastObservedTelemetryPlayhead >= _loopStartFrame &&
            _lastObservedTelemetryPlayhead <= _loopEndFrame &&
            framePos >= _loopStartFrame &&
            framePos < _loopEndFrame;
        if (isLoopWrap) {
          if (_loopWrapLeadCount > 0) {
            _loopWrapLeadCount--;
          }
        } else {
          jumpedBackwardOutsideLoop = true;
          _loopWrapLeadCount = 0;
        }
      }
      _lastObservedTelemetryPlayhead = framePos;
    }

    if (_preparedTakes.isNotEmpty && sawActiveEpochFrame) {
      if (jumpedBackwardOutsideLoop) {
        _resetTakePrefetchCursor(_lastObservedTelemetryPlayhead);
      }
      unawaited(_pumpActiveTakePrefetch());
    }
  }

  void _handleUnexpectedBackendDisconnect() {
    _isPlaying = false;
    _isCapturing = false;
    _captureTransitioning = false;
  }

  void _handleAsyncBackendError(MuseError error) {
    if (_phase != _WebLifecyclePhase.ready) {
      return;
    }
    if (error.code == MuseErrorCode.eventQueueOverflow) {
      _pendingEventQueueError ??= error;
      return;
    }
    _pendingMutationError ??= error;
    if (error.code == MuseErrorCode.audioDeviceInitFailed) {
      _handleUnexpectedBackendDisconnect();
    }
  }

  Result<void> _pushBackendMutation({
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
    final pendingMutationErr = _pendingMutationError;
    if (pendingMutationErr != null) {
      if (pendingMutationErr.code != MuseErrorCode.audioDeviceInitFailed) {
        _pendingMutationError = null;
      }
      return Err(pendingMutationErr);
    }
    return _backend.pushMutation(
      mutationType: mutationType,
      channel: channel,
      flagA: flagA,
      intParamA: intParamA,
      intParamB: intParamB,
      intParamC: intParamC,
      floatParamA: floatParamA,
      floatParamB: floatParamB,
      targetEpoch: targetEpoch,
      sampleFrameA: sampleFrameA,
      sampleFrameB: sampleFrameB,
    );
  }

  Result<int> _pushBackendEvents(List<ScheduledMidiEvent> events) {
    final pendingEventErr = _pendingEventQueueError;
    if (pendingEventErr != null) {
      _pendingEventQueueError = null;
      return Err(pendingEventErr);
    }
    final pendingMutationErr = _pendingMutationError;
    if (pendingMutationErr != null &&
        pendingMutationErr.code == MuseErrorCode.audioDeviceInitFailed) {
      return Err(pendingMutationErr);
    }
    return _backend.pushEvents(events);
  }

  void _resetTakePrefetchCursor(int? targetFrame) {
    _prefetchGeneration++;
    _loopWrapLeadCount = 0;
    final baseFrame = targetFrame ?? _lastObservedTelemetryPlayhead;
    if (_loopEnabled &&
        !_isCapturing &&
        _loopEndFrame > _loopStartFrame &&
        baseFrame >= _loopEndFrame) {
      _prefetchCursorFrame = _loopStartFrame;
    } else {
      _prefetchCursorFrame = baseFrame;
    }
  }

  Future<void> _pumpActiveTakePrefetch() async {
    if (_phase != _WebLifecyclePhase.ready || _preparedTakes.isEmpty) {
      return;
    }
    if (_prefetchPumping) {
      _prefetchNeedsAnotherPass = true;
      return;
    }

    _prefetchPumping = true;
    try {
      do {
        _prefetchNeedsAnotherPass = false;
        await _pumpSinglePrefetchPass();
      } while (_prefetchNeedsAnotherPass &&
          _phase == _WebLifecyclePhase.ready &&
          _preparedTakes.isNotEmpty);
    } finally {
      _prefetchPumping = false;
    }
  }

  Future<void> _pumpSinglePrefetchPass() async {
    final startGen = _prefetchGeneration;
    final epoch = _currentEpoch.value;
    final loopActive =
        _loopEnabled && !_isCapturing && _loopEndFrame > _loopStartFrame;
    final loopLen = loopActive ? (_loopEndFrame - _loopStartFrame) : 0;
    var maxTakeEnd = 0;
    for (final take in _preparedTakes) {
      final end = take.startSampleFrame + take.durationFrames;
      if (end > maxTakeEnd) {
        maxTakeEnd = end;
      }
    }

    while (_phase == _WebLifecyclePhase.ready &&
        _preparedTakes.isNotEmpty &&
        _prefetchGeneration == startGen) {
      final effectivePlayhead =
          (loopActive && _lastObservedTelemetryPlayhead >= _loopEndFrame)
          ? _loopStartFrame
          : _lastObservedTelemetryPlayhead;

      if (!loopActive) {
        if (_prefetchCursorFrame < effectivePlayhead) {
          _prefetchCursorFrame = effectivePlayhead;
        }
        if (_prefetchCursorFrame >= maxTakeEnd) {
          break;
        }
      } else {
        if (_prefetchCursorFrame >= _loopEndFrame) {
          _prefetchCursorFrame = _loopStartFrame;
        } else if (effectivePlayhead >= _loopStartFrame &&
            _prefetchCursorFrame < _loopStartFrame) {
          _prefetchCursorFrame = effectivePlayhead;
          _loopWrapLeadCount = 0;
        } else if (_loopWrapLeadCount == 0 &&
            _prefetchCursorFrame < effectivePlayhead) {
          _prefetchCursorFrame = effectivePlayhead;
        }
      }

      final streamAhead = loopActive
          ? math.max(
              0,
              (_loopWrapLeadCount * loopLen) +
                  (_prefetchCursorFrame - effectivePlayhead),
            )
          : math.max(0, _prefetchCursorFrame - effectivePlayhead);
      if (streamAhead >= MuseConstants.takePrefetchFrames) {
        break;
      }

      final remainingBudget = MuseConstants.takePrefetchFrames - streamAhead;
      var chunkFrames = math.min(remainingBudget, _takeStreamChunkFrames);
      if (loopActive) {
        if (_prefetchCursorFrame < _loopStartFrame) {
          chunkFrames = math.min(
            chunkFrames,
            _loopStartFrame - _prefetchCursorFrame,
          );
        } else {
          chunkFrames = math.min(
            chunkFrames,
            _loopEndFrame - _prefetchCursorFrame,
          );
        }
      } else {
        chunkFrames = math.min(chunkFrames, maxTakeEnd - _prefetchCursorFrame);
      }
      if (chunkFrames <= 0) {
        break;
      }

      final chunkStart = _prefetchCursorFrame;
      final chunkEnd = chunkStart + chunkFrames;
      final mixed = _mixPreparedTakesForRange(
        takes: _preparedTakes,
        chunkStart: chunkStart,
        chunkEnd: chunkEnd,
        chunkFrames: chunkFrames,
      );

      final pushRes = await _backend.pushTakePcm(
        epoch: epoch,
        startSampleFrame: chunkStart,
        interleavedStereoF32: mixed,
        frameCount: chunkFrames,
      );
      if (_prefetchGeneration != startGen ||
          _phase != _WebLifecyclePhase.ready) {
        break;
      }

      switch (pushRes) {
        case Ok<int>(:final value):
          if (value <= 0) {
            return;
          }
          _prefetchCursorFrame += value;
          if (loopActive && _prefetchCursorFrame >= _loopEndFrame) {
            _prefetchCursorFrame = _loopStartFrame;
            _loopWrapLeadCount++;
          }
          if (value < chunkFrames) {
            return;
          }
        case Err<int>(:final error):
          if (error.code == MuseErrorCode.takePlaybackBufferUnderrun) {
            // TakePlaybackRingBuffer reached capacity; resume on next telemetry batch.
            return;
          }
          return;
      }
    }
  }

  static Float32List _mixPreparedTakesForRange({
    required List<_PreparedWebTake> takes,
    required int chunkStart,
    required int chunkEnd,
    required int chunkFrames,
  }) {
    final out = Float32List(chunkFrames * _stereoChannels);
    for (final take in takes) {
      final takeEnd = take.startSampleFrame + take.durationFrames;
      final ovStart = math.max(chunkStart, take.startSampleFrame);
      final ovEnd = math.min(chunkEnd, takeEnd);
      if (ovStart >= ovEnd) {
        continue;
      }
      final srcStartFrame = ovStart - take.startSampleFrame;
      final dstStartFrame = ovStart - chunkStart;
      final overlapFrames = ovEnd - ovStart;
      final src = take.interleavedStereoF32;
      for (var f = 0; f < overlapFrames; f++) {
        final srcIdx = (srcStartFrame + f) * _stereoChannels;
        final dstIdx = (dstStartFrame + f) * _stereoChannels;
        if (srcIdx + 1 >= src.length) {
          break;
        }
        out[dstIdx] += src[srcIdx];
        out[dstIdx + 1] += src[srcIdx + 1];
      }
    }
    return out;
  }
}

final class _PreparedWebTake {
  final String takeId;
  final String casPath;
  final int startSampleFrame;
  final int durationFrames;
  final double gainDb;
  final double pan;
  final Float32List interleavedStereoF32;

  const _PreparedWebTake({
    required this.takeId,
    required this.casPath,
    required this.startSampleFrame,
    required this.durationFrames,
    required this.gainDb,
    required this.pan,
    required this.interleavedStereoF32,
  });
}

// -----------------------------------------------------------------------------
// Browser package:web + dart:js_interop Implementation
// -----------------------------------------------------------------------------

final class _BrowserWebAudioHostBackend implements WebAudioHostBackend {
  static const String _wasmUrl = 'muse_audio_engine.wasm';
  static const String _wasmGlueUrl = 'muse_audio_engine.js';
  static const String _workletProcessorUrl = 'muse_audio_worklet_processor.js';
  static const String _workletProcessorName = 'muse-audio-worklet-processor';
  static const String _opfsWorkerUrl = 'muse_opfs_audio_worker.js';
  static const String _deviceFingerprint = 'web-audioworklet-wasm';
  static const int _stereoOutputChannels = 2;
  static const int _monoInputChannels = 1;
  static const int _flagIsPlayingMask = 1 << 0;
  static const int _flagIsCapturingMask = 1 << 1;
  static const int _flagEventUnderrunMask = 1 << 2;
  static const int _flagCaptureOverflowMask = 1 << 3;
  static const int _flagTakeUnderrunMask = 1 << 4;
  static const int _flagLoopPassShiftBits = 16;
  static const int _flagLoopPassMask = 0xFFFF;

  web.AudioContext? _audioContext;
  web.AudioWorkletNode? _workletNode;
  web.Worker? _opfsWorker;
  web.MediaStream? _micStream;
  web.MediaStreamAudioSourceNode? _micSource;

  void Function(List<TelemetrySnapshot>)? _onTelemetryBatch;
  void Function()? _onUnexpectedDisconnect;
  void Function(MuseError error)? _onAsyncError;
  MuseError? _pendingAsyncError;

  bool _disposed = false;
  int _nextRequestId = 1;
  Completer<Result<AudioHardwareInfo>>? _readyCompleter;
  final Map<int, Completer<JSObject>> _pendingWorkletRequests =
      <int, Completer<JSObject>>{};
  final Map<int, Completer<JSObject>> _pendingCaptureFlushRequests =
      <int, Completer<JSObject>>{};
  final Map<int, Completer<JSObject>> _pendingWorkerRequests =
      <int, Completer<JSObject>>{};

  @override
  bool get isSecureContext => web.window.isSecureContext;

  @override
  Future<Result<AudioHardwareInfo>> startSession({
    required void Function(List<TelemetrySnapshot> frames) onTelemetryBatch,
    required void Function() onUnexpectedDisconnect,
    void Function(MuseError error)? onAsyncError,
  }) async {
    _disposed = false;
    _pendingAsyncError = null;
    _onTelemetryBatch = onTelemetryBatch;
    _onUnexpectedDisconnect = onUnexpectedDisconnect;
    _onAsyncError = onAsyncError;

    web.AudioContext? context;
    web.AudioWorkletNode? workletNode;
    web.Worker? opfsWorker;

    try {
      // Rule 15: never hardcode browser sample rate; let AudioContext negotiate native rate.
      context = web.AudioContext();
      await context.resume().toDart;
      if (context.state != 'running') {
        await context.close().toDart;
        return const Err(
          MuseError(
            MuseErrorCode.webAudioUserGestureRequired,
            'AudioContext stayed suspended; explicit user gesture required.',
          ),
        );
      }

      final response = await web.window.fetch(_wasmUrl.toJS).toDart;
      if (!response.ok) {
        await context.close().toDart;
        return Err(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Failed to fetch $_wasmUrl (HTTP ${response.status}).',
          ),
        );
      }
      final wasmBuffer = await response.arrayBuffer().toDart;

      await context.audioWorklet.addModule(_wasmGlueUrl).toDart;
      await context.audioWorklet.addModule(_workletProcessorUrl).toDart;

      final procOpts = JSObject()
        ..setProperty('wasmBinary'.toJS, wasmBuffer)
        ..setProperty('sampleRate'.toJS, context.sampleRate.toJS)
        ..setProperty(
          'outputBufferFrames'.toJS,
          RiffWavCodec.webRenderQuantumFrames.toJS,
        )
        ..setProperty('deviceFingerprint'.toJS, _deviceFingerprint.toJS)
        ..setProperty(
          'captureBatchQuanta'.toJS,
          MuseConstants.webCaptureBatchQuanta.toJS,
        );

      final nodeOptions = web.AudioWorkletNodeOptions(
        numberOfInputs: _monoInputChannels,
        numberOfOutputs: 1,
        outputChannelCount: <JSNumber>[_stereoOutputChannels.toJS].toJS,
        processorOptions: procOpts,
      );
      workletNode = web.AudioWorkletNode(
        context,
        _workletProcessorName,
        nodeOptions,
      );

      final readyCompleter = Completer<Result<AudioHardwareInfo>>();
      _readyCompleter = readyCompleter;

      workletNode.port.onmessage = ((web.MessageEvent event) {
        _handleWorkletMessage(event.data);
      }).toJS;
      workletNode.port.onmessageerror = ((web.Event _) {
        _onUnexpectedDisconnect?.call();
      }).toJS;

      workletNode.connect(context.destination);

      opfsWorker = web.Worker(_opfsWorkerUrl.toJS);
      opfsWorker.onmessage = ((web.MessageEvent event) {
        _handleOpfsWorkerMessage(event.data);
      }).toJS;

      _audioContext = context;
      _workletNode = workletNode;
      _opfsWorker = opfsWorker;

      final readyResult = await readyCompleter.future;
      if (readyResult.isErr) {
        await dispose();
      }
      return readyResult;
    } on Object catch (error) {
      await _cleanupPartialStart(
        context: context,
        workletNode: workletNode,
        opfsWorker: opfsWorker,
      );
      return Err(_translateJsFailure(error, context: WebBridgeOpContext.lifecycle));
    }
  }

  Future<void> _cleanupPartialStart({
    required web.AudioContext? context,
    required web.AudioWorkletNode? workletNode,
    required web.Worker? opfsWorker,
  }) async {
    _readyCompleter = null;
    try {
      workletNode?.disconnect();
    } catch (_) {}
    opfsWorker?.terminate();
    if (context != null && context.state != 'closed') {
      try {
        await context.close().toDart;
      } catch (_) {}
    }
    _audioContext = null;
    _workletNode = null;
    _opfsWorker = null;
  }

  void _handleWorkletMessage(JSAny? raw) {
    if (raw == null || !raw.isA<JSObject>()) {
      return;
    }
    final msg = raw as JSObject;
    final typeAny = msg.getProperty('type'.toJS);
    if (typeAny == null || !typeAny.isA<JSString>()) {
      return;
    }
    final type = (typeAny as JSString).toDart;

    switch (type) {
      case 'ready':
        final readyCompleter = _readyCompleter;
        _readyCompleter = null;
        if (readyCompleter != null && !readyCompleter.isCompleted) {
          final hwAny = msg.getProperty('hardwareInfo'.toJS);
          if (hwAny != null && hwAny.isA<JSObject>()) {
            final hwObj = hwAny as JSObject;
            final info = AudioHardwareInfo(
              sampleRate: _readInt(hwObj, 'sampleRate'),
              inputChannels: _readInt(hwObj, 'inputChannels'),
              outputChannels: _readInt(hwObj, 'outputChannels'),
              inputBufferFrames: _readInt(hwObj, 'inputBufferFrames'),
              outputBufferFrames: _readInt(hwObj, 'outputBufferFrames'),
              deviceFingerprint: _readString(hwObj, 'deviceFingerprint'),
            );
            readyCompleter.complete(Ok(info));
          } else {
            readyCompleter.complete(
              const Err(
                MuseError(
                  MuseErrorCode.audioDeviceInitFailed,
                  'AudioWorklet ready message missing hardwareInfo.',
                ),
              ),
            );
          }
        }
      case 'initError':
        final readyCompleter = _readyCompleter;
        _readyCompleter = null;
        if (readyCompleter != null && !readyCompleter.isCompleted) {
          readyCompleter.complete(
            Err(
              MuseError(
                MuseErrorCode.audioDeviceInitFailed,
                _readString(msg, 'message', fallback: 'Worklet Wasm init failed.'),
              ),
            ),
          );
        }
      case 'response':
        final reqId = _readInt(msg, 'requestId', fallback: -1);
        final completer = _pendingWorkletRequests.remove(reqId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(msg);
        }
      case 'captureChunk':
        final opfsWorker = _opfsWorker;
        final samplesBuffer = msg.getProperty('samples'.toJS);
        if (opfsWorker != null && samplesBuffer != null && samplesBuffer.isA<JSArrayBuffer>()) {
          final forward = JSObject()
            ..setProperty('type'.toJS, 'appendCapturePcm'.toJS)
            ..setProperty(
              'firstSampleClock'.toJS,
              (_readDouble(msg, 'firstSampleClock')).toJS,
            )
            ..setProperty('samplesBuffer'.toJS, samplesBuffer);
          opfsWorker.postMessage(forward, <JSAny>[samplesBuffer].toJS);
        }
      case 'captureFlushed':
        final reqId = _readInt(msg, 'requestId', fallback: -1);
        final completer = _pendingCaptureFlushRequests.remove(reqId);
        if (completer != null && !completer.isCompleted) {
          completer.complete(msg);
        }
      case 'telemetry':
        final framesAny = msg.getProperty('frames'.toJS);
        if (framesAny == null || !framesAny.isA<JSArray>()) {
          return;
        }
        final jsFrames = (framesAny as JSArray).toDart;
        if (jsFrames.isEmpty) {
          return;
        }
        final decoded = <TelemetrySnapshot>[];
        for (final item in jsFrames) {
          if (item == null || !item.isA<JSObject>()) {
            continue;
          }
          final f = item as JSObject;
          final flags = _readInt(f, 'flags');
          decoded.add(
            TelemetrySnapshot(
              playheadSampleFrame: SampleFrame(
                _readDouble(f, 'playheadSampleFrame').round(),
              ),
              activeEpoch: EpochId(_readDouble(f, 'activeEpoch').round()),
              outputPeakL: _readDouble(f, 'outputPeakL'),
              outputPeakR: _readDouble(f, 'outputPeakR'),
              outputRmsL: _readDouble(f, 'outputRmsL'),
              outputRmsR: _readDouble(f, 'outputRmsR'),
              inputPeak: _readDouble(f, 'inputPeak'),
              inputRms: _readDouble(f, 'inputRms'),
              isPlaying: (flags & _flagIsPlayingMask) != 0,
              isCapturing: (flags & _flagIsCapturingMask) != 0,
              hasEventQueueUnderrun: (flags & _flagEventUnderrunMask) != 0,
              hasCaptureBufferOverflow:
                  (flags & _flagCaptureOverflowMask) != 0,
              hasTakePlaybackUnderrun: (flags & _flagTakeUnderrunMask) != 0,
              loopPass:
                  (flags >>> _flagLoopPassShiftBits) & _flagLoopPassMask,
            ),
          );
        }
        if (decoded.isNotEmpty) {
          _onTelemetryBatch?.call(decoded);
        }
      case 'bridgeError':
        final operation = _readString(msg, 'operation');
        final status = _readInt(
          msg,
          'status',
          fallback: WebBridgeErrorMapper.museErrDeviceInit,
        );
        final mapped = WebBridgeErrorMapper.mapMuseStatus(
          status,
          context: operation == 'pushEvents'
              ? WebBridgeOpContext.synthEvent
              : WebBridgeOpContext.lifecycle,
        );
        final asyncCb = _onAsyncError;
        if (asyncCb != null) {
          asyncCb(mapped);
        } else {
          _pendingAsyncError ??= mapped;
        }
        if (status == WebBridgeErrorMapper.museErrDeviceInit) {
          _onUnexpectedDisconnect?.call();
        }
    }
  }

  void _handleOpfsWorkerMessage(JSAny? raw) {
    if (raw == null || !raw.isA<JSObject>()) {
      return;
    }
    final msg = raw as JSObject;
    final reqId = _readInt(msg, 'requestId', fallback: -1);
    final completer = _pendingWorkerRequests.remove(reqId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(msg);
    }
  }

  Future<Result<JSObject>> _awaitBackendRequest({
    required Completer<JSObject> completer,
    required Map<int, Completer<JSObject>> pendingMap,
    required int reqId,
    required void Function() dispatch,
    required MuseErrorCode errorCode,
  }) async {
    pendingMap[reqId] = completer;
    try {
      dispatch();
      final reply = await completer.future;
      if (_disposed) {
        return Err(
          MuseError(errorCode, 'Web audio host backend was disposed mid-flight.'),
        );
      }
      return Ok(reply);
    } on _BackendDisposedException {
      return Err(
        MuseError(errorCode, 'Web audio host backend was disposed mid-flight.'),
      );
    } on Object catch (error) {
      pendingMap.remove(reqId);
      return Err(MuseError(errorCode, 'Web audio host request failed: $error'));
    }
  }

  Future<Result<JSObject>> _sendWorkletRequest(
    JSObject msg, {
    required MuseErrorCode errorCode,
    List<JSAny>? transfer,
    bool awaitCaptureFlush = false,
  }) async {
    if (_disposed) {
      return Err(MuseError(errorCode, 'Web audio host backend is disposed.'));
    }
    final port = _workletNode?.port;
    if (port == null) {
      return Err(MuseError(errorCode, 'AudioWorkletNode port is not open.'));
    }
    final reqId = _nextRequestId++;
    msg.setProperty('requestId'.toJS, reqId.toJS);
    return _awaitBackendRequest(
      completer: Completer<JSObject>(),
      pendingMap: awaitCaptureFlush
          ? _pendingCaptureFlushRequests
          : _pendingWorkletRequests,
      reqId: reqId,
      errorCode: errorCode,
      dispatch: () {
        if (transfer != null && transfer.isNotEmpty) {
          port.postMessage(msg, transfer.toJS);
        } else {
          port.postMessage(msg);
        }
      },
    );
  }

  Future<Result<JSObject>> _sendWorkerRequest(
    JSObject msg, {
    required MuseErrorCode errorCode,
  }) async {
    if (_disposed) {
      return Err(MuseError(errorCode, 'Web audio host backend is disposed.'));
    }
    final worker = _opfsWorker;
    if (worker == null) {
      return Err(MuseError(errorCode, 'OPFS audio worker is not running.'));
    }
    final reqId = _nextRequestId++;
    msg.setProperty('requestId'.toJS, reqId.toJS);
    return _awaitBackendRequest(
      completer: Completer<JSObject>(),
      pendingMap: _pendingWorkerRequests,
      reqId: reqId,
      errorCode: errorCode,
      dispatch: () => worker.postMessage(msg),
    );
  }

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSf2Bytes({
    required Sha256Digest sha256,
    required Uint8List bytes,
  }) async {
    final jsBuffer = bytes.buffer.toJS;
    final msg = JSObject()
      ..setProperty('type'.toJS, 'loadSf2Bytes'.toJS)
      ..setProperty('bytes'.toJS, jsBuffer);

    final replyRes = await _sendWorkletRequest(
      msg,
      errorCode: MuseErrorCode.soundFontLoadFailed,
      transfer: <JSAny>[jsBuffer],
    );
    final JSObject reply;
    switch (replyRes) {
      case Err<JSObject>(:final error):
        return Err(error);
      case Ok<JSObject>(:final value):
        reply = value;
    }
    final status = _readInt(
      reply,
      'status',
      fallback: WebBridgeErrorMapper.museErrSfLoadFailed,
    );
    if (status != WebBridgeErrorMapper.museOk) {
      return Err(
        WebBridgeErrorMapper.mapMuseStatus(
          status,
          context: WebBridgeOpContext.soundFontWeb,
        ),
      );
    }

    final sfHandle = _readInt(reply, 'sfHandle', fallback: -1);
    if (sfHandle <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'Wasm SoundFont loader returned an invalid handle.',
        ),
      );
    }

    final presets = <SoundFontPresetInfo>[];
    final presetsAny = reply.getProperty('presets'.toJS);
    if (presetsAny != null && presetsAny.isA<JSArray>()) {
      for (final item in (presetsAny as JSArray).toDart) {
        if (item == null || !item.isA<JSObject>()) {
          continue;
        }
        final obj = item as JSObject;
        presets.add(
          SoundFontPresetInfo(
            bankNum: _readInt(obj, 'bankNum'),
            programNum: _readInt(obj, 'programNum'),
            presetName: _readString(obj, 'presetName'),
          ),
        );
      }
    }

    return Ok(
      LoadedSoundFontDescriptor(
        handle: SoundFontHandle(sfHandle),
        presets: List<SoundFontPresetInfo>.unmodifiable(presets),
      ),
    );
  }

  @override
  Future<Result<void>> unloadSf2(int sfHandle) async {
    final msg = JSObject()
      ..setProperty('type'.toJS, 'unloadSf2'.toJS)
      ..setProperty('sfHandle'.toJS, sfHandle.toJS);
    final replyRes = await _sendWorkletRequest(
      msg,
      errorCode: MuseErrorCode.soundFontLoadFailed,
    );
    final JSObject reply;
    switch (replyRes) {
      case Err<JSObject>(:final error):
        return Err(error);
      case Ok<JSObject>(:final value):
        reply = value;
    }
    final status = _readInt(
      reply,
      'status',
      fallback: WebBridgeErrorMapper.museErrSfLoadFailed,
    );
    if (status != WebBridgeErrorMapper.museOk) {
      return Err(
        WebBridgeErrorMapper.mapMuseStatus(
          status,
          context: WebBridgeOpContext.soundFontWeb,
        ),
      );
    }
    return const Ok(null);
  }

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
    final pendingErr = _pendingAsyncError;
    if (pendingErr != null) {
      _pendingAsyncError = null;
      return Err(pendingErr);
    }
    final port = _workletNode?.port;
    if (port == null) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'AudioWorkletNode port is unavailable.',
        ),
      );
    }
    final msg = JSObject()
      ..setProperty('type'.toJS, 'pushMutation'.toJS)
      ..setProperty('mutationType'.toJS, mutationType.toJS)
      ..setProperty('channel'.toJS, channel.toJS)
      ..setProperty('flagA'.toJS, flagA.toJS)
      ..setProperty('intParamA'.toJS, intParamA.toJS)
      ..setProperty('intParamB'.toJS, intParamB.toJS)
      ..setProperty('intParamC'.toJS, intParamC.toJS)
      ..setProperty('floatParamA'.toJS, floatParamA.toJS)
      ..setProperty('floatParamB'.toJS, floatParamB.toJS)
      ..setProperty('targetEpoch'.toJS, targetEpoch.toDouble().toJS)
      ..setProperty('sampleFrameA'.toJS, sampleFrameA.toDouble().toJS)
      ..setProperty('sampleFrameB'.toJS, sampleFrameB.toDouble().toJS);
    try {
      port.postMessage(msg);
      return const Ok(null);
    } on Object catch (error) {
      return Err(
        _translateJsFailure(error, context: WebBridgeOpContext.lifecycle),
      );
    }
  }

  @override
  Result<int> pushEvents(List<ScheduledMidiEvent> events) {
    final pendingErr = _pendingAsyncError;
    if (pendingErr != null) {
      _pendingAsyncError = null;
      return Err(pendingErr);
    }
    if (events.length > RiffWavCodec.eventQueueCapacity) {
      return Err(
        MuseError(
          MuseErrorCode.eventQueueOverflow,
          'Event batch (${events.length}) exceeds queue capacity ${RiffWavCodec.eventQueueCapacity}.',
        ),
      );
    }
    final port = _workletNode?.port;
    if (port == null) {
      return const Err(
        MuseError(
          MuseErrorCode.eventQueueOverflow,
          'AudioWorkletNode port is unavailable.',
        ),
      );
    }
    final jsEvents = <JSObject>[];
    for (final e in events) {
      jsEvents.add(
        JSObject()
          ..setProperty('epoch'.toJS, e.epoch.value.toDouble().toJS)
          ..setProperty(
            'targetSampleFrame'.toJS,
            e.targetSampleFrame.value.toDouble().toJS,
          )
          ..setProperty('type'.toJS, e.type.toJS)
          ..setProperty('channel'.toJS, e.channel.toJS)
          ..setProperty('keyOrCc'.toJS, e.data1.toJS)
          ..setProperty('velocityOrVal'.toJS, e.data2.toJS)
          ..setProperty('pitchBend'.toJS, e.pitchBend.toJS)
          ..setProperty('loopPass'.toJS, e.loopPass.toJS),
      );
    }
    final msg = JSObject()
      ..setProperty('type'.toJS, 'pushEvents'.toJS)
      ..setProperty('events'.toJS, jsEvents.toJS);
    try {
      port.postMessage(msg);
      return Ok(events.length);
    } on Object catch (error) {
      return Err(
        _translateJsFailure(error, context: WebBridgeOpContext.synthEvent),
      );
    }
  }

  @override
  Future<Result<void>> clearActiveTakes() async {
    final msg = JSObject()..setProperty('type'.toJS, 'clearActiveTakes'.toJS);
    final replyRes = await _sendWorkletRequest(
      msg,
      errorCode: MuseErrorCode.takeLoadFailed,
    );
    final JSObject reply;
    switch (replyRes) {
      case Err<JSObject>(:final error):
        return Err(error);
      case Ok<JSObject>(:final value):
        reply = value;
    }
    final status = _readInt(
      reply,
      'status',
      fallback: WebBridgeErrorMapper.museErrTakeLoadFailed,
    );
    if (status != WebBridgeErrorMapper.museOk) {
      return Err(
        WebBridgeErrorMapper.mapMuseStatus(
          status,
          context: WebBridgeOpContext.takePlayback,
        ),
      );
    }
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
    final msg = JSObject()
      ..setProperty('type'.toJS, 'registerActiveTake'.toJS)
      ..setProperty('takeId'.toJS, takeId.toJS)
      ..setProperty('casPath'.toJS, casPath.toJS)
      ..setProperty('startSampleFrame'.toJS, startSampleFrame.toDouble().toJS)
      ..setProperty('durationFrames'.toJS, durationFrames.toDouble().toJS)
      ..setProperty('gainDb'.toJS, gainDb.toJS)
      ..setProperty('pan'.toJS, pan.toJS);
    final replyRes = await _sendWorkletRequest(
      msg,
      errorCode: MuseErrorCode.takeLoadFailed,
    );
    final JSObject reply;
    switch (replyRes) {
      case Err<JSObject>(:final error):
        return Err(error);
      case Ok<JSObject>(:final value):
        reply = value;
    }
    final status = _readInt(
      reply,
      'status',
      fallback: WebBridgeErrorMapper.museErrTakeLoadFailed,
    );
    if (status != WebBridgeErrorMapper.museOk) {
      return Err(
        WebBridgeErrorMapper.mapMuseStatus(
          status,
          context: WebBridgeOpContext.takePlayback,
        ),
      );
    }
    return const Ok(null);
  }

  @override
  Future<Result<int>> pushTakePcm({
    required int epoch,
    required int startSampleFrame,
    required Float32List interleavedStereoF32,
    required int frameCount,
  }) async {
    final transferCopy = Float32List.fromList(interleavedStereoF32);
    final jsBuffer = transferCopy.buffer.toJS;
    final msg = JSObject()
      ..setProperty('type'.toJS, 'pushTakePcm'.toJS)
      ..setProperty('epoch'.toJS, epoch.toDouble().toJS)
      ..setProperty('startSampleFrame'.toJS, startSampleFrame.toDouble().toJS)
      ..setProperty('frameCount'.toJS, frameCount.toJS)
      ..setProperty('pcmBuffer'.toJS, jsBuffer);

    final replyRes = await _sendWorkletRequest(
      msg,
      errorCode: MuseErrorCode.takeLoadFailed,
      transfer: <JSAny>[jsBuffer],
    );
    final JSObject reply;
    switch (replyRes) {
      case Err<JSObject>(:final error):
        return Err(error);
      case Ok<JSObject>(:final value):
        reply = value;
    }
    final status = _readInt(
      reply,
      'status',
      fallback: WebBridgeErrorMapper.museErrTakeLoadFailed,
    );
    final pushed = _readInt(reply, 'pushedFrames');
    if (status != WebBridgeErrorMapper.museOk) {
      if (status == WebBridgeErrorMapper.museErrQueueFull && pushed > 0) {
        return Ok(pushed);
      }
      return Err(
        WebBridgeErrorMapper.mapMuseStatus(
          status,
          context: WebBridgeOpContext.takePlayback,
        ),
      );
    }
    return Ok(pushed);
  }

  @override
  Future<Result<void>> prepareAndStartCapture({
    required String stagingPath,
    required AudioHardwareInfo hardwareInfo,
  }) async {
    if (_disposed) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Web audio host backend is disposed.',
        ),
      );
    }
    final context = _audioContext;
    final workletNode = _workletNode;
    if (context == null || workletNode == null) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Web audio context is not running.',
        ),
      );
    }

    web.MediaStream? micStream;
    web.MediaStreamAudioSourceNode? micSource;
    try {
      final constraints = web.MediaStreamConstraints(
        audio: web.MediaTrackConstraints(
          echoCancellation: false.toJS,
          noiseSuppression: false.toJS,
          autoGainControl: false.toJS,
        ),
      );
      micStream = await web.window.navigator.mediaDevices
          .getUserMedia(constraints)
          .toDart;
      if (_disposed || _audioContext == null || _workletNode == null) {
        _stopMicStream(micSource: null, micStream: micStream);
        return const Err(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Web audio session was disposed while requesting microphone access.',
          ),
        );
      }
      micSource = context.createMediaStreamSource(micStream);
      micSource.connect(workletNode);
    } on Object catch (error) {
      _stopMicStream(micSource: micSource, micStream: micStream);
      return Err(
        _translateJsFailure(
          error,
          context: WebBridgeOpContext.capturePermission,
        ),
      );
    }

    final prepWorkerMsg = JSObject()
      ..setProperty('type'.toJS, 'prepareStagingFile'.toJS)
      ..setProperty('stagingPath'.toJS, stagingPath.toJS)
      ..setProperty('sampleRate'.toJS, hardwareInfo.sampleRate.toJS)
      ..setProperty('channelCount'.toJS, hardwareInfo.inputChannels.toJS);
    final workerReplyRes = await _sendWorkerRequest(
      prepWorkerMsg,
      errorCode: MuseErrorCode.casPromotionFailed,
    );
    final JSObject workerReply;
    switch (workerReplyRes) {
      case Err<JSObject>(:final error):
        _stopMicStream(micSource: micSource, micStream: micStream);
        return Err(error);
      case Ok<JSObject>(:final value):
        workerReply = value;
    }
    if (!_readBool(workerReply, 'ok')) {
      _stopMicStream(micSource: micSource, micStream: micStream);
      return Err(
        WebBridgeErrorMapper.mapDomException(
          _readString(workerReply, 'errorName'),
          context: WebBridgeOpContext.captureStorage,
          detail: _readString(workerReply, 'message'),
        ),
      );
    }

    final prepWorkletMsg = JSObject()
      ..setProperty('type'.toJS, 'prepareCapture'.toJS)
      ..setProperty('stagingPath'.toJS, stagingPath.toJS);
    final prepWorkletReplyRes = await _sendWorkletRequest(
      prepWorkletMsg,
      errorCode: MuseErrorCode.casPromotionFailed,
    );
    final JSObject prepWorkletReply;
    switch (prepWorkletReplyRes) {
      case Err<JSObject>(:final error):
        await _abortOpfsStaging();
        _stopMicStream(micSource: micSource, micStream: micStream);
        return Err(error);
      case Ok<JSObject>(:final value):
        prepWorkletReply = value;
    }
    final prepStatus = _readInt(
      prepWorkletReply,
      'status',
      fallback: WebBridgeErrorMapper.museErrDeviceInit,
    );
    if (prepStatus != WebBridgeErrorMapper.museOk) {
      await _abortOpfsStaging();
      _stopMicStream(micSource: micSource, micStream: micStream);
      return Err(
        WebBridgeErrorMapper.mapMuseStatus(
          prepStatus,
          context: WebBridgeOpContext.captureStorage,
        ),
      );
    }

    final startWorkletMsg = JSObject()
      ..setProperty('type'.toJS, 'startCapture'.toJS);
    final startWorkletReplyRes = await _sendWorkletRequest(
      startWorkletMsg,
      errorCode: MuseErrorCode.casPromotionFailed,
    );
    final JSObject startWorkletReply;
    switch (startWorkletReplyRes) {
      case Err<JSObject>(:final error):
        await _abortOpfsStaging();
        _stopMicStream(micSource: micSource, micStream: micStream);
        return Err(error);
      case Ok<JSObject>(:final value):
        startWorkletReply = value;
    }
    final startStatus = _readInt(
      startWorkletReply,
      'status',
      fallback: WebBridgeErrorMapper.museErrDeviceInit,
    );
    if (startStatus != WebBridgeErrorMapper.museOk) {
      await _abortOpfsStaging();
      _stopMicStream(micSource: micSource, micStream: micStream);
      return Err(
        WebBridgeErrorMapper.mapMuseStatus(
          startStatus,
          context: WebBridgeOpContext.captureStorage,
        ),
      );
    }

    if (_disposed) {
      await _abortOpfsStaging();
      _stopMicStream(micSource: micSource, micStream: micStream);
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Web audio session was disposed while starting capture.',
        ),
      );
    }

    _micStream = micStream;
    _micSource = micSource;
    return const Ok(null);
  }

  @override
  Future<Result<WebCaptureFinalizedResult>> stopAndFinalizeCapture({
    required String stagingPath,
  }) async {
    final flushMsg = JSObject()
      ..setProperty('type'.toJS, 'stopCaptureAndFlush'.toJS);
    final flushReplyRes = await _sendWorkletRequest(
      flushMsg,
      errorCode: MuseErrorCode.casPromotionFailed,
      awaitCaptureFlush: true,
    );
    _stopMicStream(micSource: _micSource, micStream: _micStream);
    _micSource = null;
    _micStream = null;

    final JSObject flushReply;
    switch (flushReplyRes) {
      case Err<JSObject>(:final error):
        return Err(error);
      case Ok<JSObject>(:final value):
        flushReply = value;
    }

    final hasOverflowed = _readBool(flushReply, 'hasOverflowed');
    final capturedPlayheadFrame = _readDouble(
      flushReply,
      'capturedPlayheadFrame',
    ).round();

    final finMsg = JSObject()
      ..setProperty('type'.toJS, 'finalizeStagingFile'.toJS)
      ..setProperty('cancelledOrOverflowed'.toJS, hasOverflowed.toJS);
    final workerReplyRes = await _sendWorkerRequest(
      finMsg,
      errorCode: MuseErrorCode.casPromotionFailed,
    );
    final JSObject workerReply;
    switch (workerReplyRes) {
      case Err<JSObject>(:final error):
        return Err(error);
      case Ok<JSObject>(:final value):
        workerReply = value;
    }

    if (hasOverflowed) {
      return const Err(
        MuseError(
          MuseErrorCode.captureBufferOverflow,
          'Web CaptureRingBuffer overflowed before OPFS worker drained frames.',
        ),
      );
    }

    if (!_readBool(workerReply, 'ok')) {
      return Err(
        WebBridgeErrorMapper.mapDomException(
          _readString(workerReply, 'errorName'),
          context: WebBridgeOpContext.captureStorage,
          detail: _readString(workerReply, 'message'),
        ),
      );
    }

    return Ok(
      WebCaptureFinalizedResult(
        durationFrames: _readInt(workerReply, 'durationFrames'),
        capturedSampleClock: _readDouble(
          workerReply,
          'capturedSampleClock',
        ).round(),
        capturedPlayheadFrame: capturedPlayheadFrame,
        hasOverflowed: false,
      ),
    );
  }

  @override
  Future<Result<String>> computeOpfsFileSha256(String stagingPath) async {
    try {
      final segments = stagingPath
          .replaceAll('\\', '/')
          .split('/')
          .where((seg) => seg.isNotEmpty && seg != '.')
          .toList(growable: false);
      if (segments.isEmpty || segments.contains('..')) {
        return Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'Invalid OPFS staging path for SHA-256 verification: $stagingPath',
          ),
        );
      }

      var dir = await web.window.navigator.storage.getDirectory().toDart;
      for (var i = 0; i < segments.length - 1; i++) {
        dir = await dir.getDirectoryHandle(segments[i]).toDart;
      }
      final fileHandle = await dir.getFileHandle(segments.last).toDart;
      final file = await fileHandle.getFile().toDart;
      final totalBytes = file.size.toInt();

      final sink = _SingleDigestSink();
      final byteSink = sha256.startChunkedConversion(sink);
      for (
        var offset = 0;
        offset < totalBytes;
        offset += RiffWavCodec.sha256FileChunkBytes
      ) {
        final end = math.min(
          offset + RiffWavCodec.sha256FileChunkBytes,
          totalBytes,
        );
        final chunkBlob = file.slice(offset, end);
        final jsBuf = await chunkBlob.arrayBuffer().toDart;
        byteSink.add(Uint8List.view(jsBuf.toDart));
      }
      byteSink.close();
      return Ok(sink.value.toString());
    } on Object catch (error) {
      return Err(
        _translateJsFailure(
          error,
          context: WebBridgeOpContext.captureStorage,
        ),
      );
    }
  }

  @override
  Future<void> dispose() async {
    _disposed = true;
    _pendingAsyncError = null;
    _onAsyncError = null;
    final ready = _readyCompleter;
    _readyCompleter = null;
    if (ready != null && !ready.isCompleted) {
      ready.complete(
        const Err(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Web audio host backend disposed before initialization completed.',
          ),
        ),
      );
    }
    for (final c in _pendingWorkletRequests.values) {
      if (!c.isCompleted) {
        c.completeError(const _BackendDisposedException());
      }
    }
    _pendingWorkletRequests.clear();
    for (final c in _pendingCaptureFlushRequests.values) {
      if (!c.isCompleted) {
        c.completeError(const _BackendDisposedException());
      }
    }
    _pendingCaptureFlushRequests.clear();
    for (final c in _pendingWorkerRequests.values) {
      if (!c.isCompleted) {
        c.completeError(const _BackendDisposedException());
      }
    }
    _pendingWorkerRequests.clear();

    _stopMicStream(micSource: _micSource, micStream: _micStream);
    _micSource = null;
    _micStream = null;

    final worklet = _workletNode;
    _workletNode = null;
    if (worklet != null) {
      try {
        worklet.port.postMessage(
          JSObject()..setProperty('type'.toJS, 'dispose'.toJS),
        );
      } catch (_) {}
      try {
        worklet.disconnect();
      } catch (_) {}
    }

    final worker = _opfsWorker;
    _opfsWorker = null;
    worker?.terminate();

    final context = _audioContext;
    _audioContext = null;
    if (context != null && context.state != 'closed') {
      try {
        await context.close().toDart;
      } catch (_) {}
    }
  }

  Future<void> _abortOpfsStaging() async {
    if (_disposed) {
      return;
    }
    await _sendWorkerRequest(
      JSObject()
        ..setProperty('type'.toJS, 'finalizeStagingFile'.toJS)
        ..setProperty('cancelledOrOverflowed'.toJS, true.toJS),
      errorCode: MuseErrorCode.casPromotionFailed,
    );
  }

  static void _stopMicStream({
    required web.MediaStreamAudioSourceNode? micSource,
    required web.MediaStream? micStream,
  }) {
    try {
      micSource?.disconnect();
    } catch (_) {}
    if (micStream != null) {
      for (final track in micStream.getAudioTracks().toDart) {
        try {
          track.stop();
        } catch (_) {}
      }
    }
  }

  static MuseError _translateJsFailure(
    Object error, {
    required WebBridgeOpContext context,
  }) {
    final text = error.toString();
    for (final domName in const <String>[
      'NotAllowedError',
      'SecurityError',
      'QuotaExceededError',
      'NotFoundError',
      'AbortError',
      'InvalidStateError',
    ]) {
      if (text.contains(domName)) {
        return WebBridgeErrorMapper.mapDomException(
          domName,
          context: context,
          detail: text,
        );
      }
    }
    return MuseError(
      context == WebBridgeOpContext.captureStorage
          ? MuseErrorCode.casPromotionFailed
          : MuseErrorCode.audioDeviceInitFailed,
      'Web audio failure: $text',
      cause: error,
    );
  }

  static int _readInt(JSObject obj, String key, {int fallback = 0}) {
    final v = obj.getProperty(key.toJS);
    if (v != null && v.isA<JSNumber>()) {
      return (v as JSNumber).toDartInt;
    }
    return fallback;
  }

  static double _readDouble(JSObject obj, String key, {double fallback = 0.0}) {
    final v = obj.getProperty(key.toJS);
    if (v != null && v.isA<JSNumber>()) {
      return (v as JSNumber).toDartDouble;
    }
    return fallback;
  }

  static bool _readBool(JSObject obj, String key, {bool fallback = false}) {
    final v = obj.getProperty(key.toJS);
    if (v != null && v.isA<JSBoolean>()) {
      return (v as JSBoolean).toDart;
    }
    return fallback;
  }

  static String _readString(JSObject obj, String key, {String fallback = ''}) {
    final v = obj.getProperty(key.toJS);
    if (v != null && v.isA<JSString>()) {
      return (v as JSString).toDart;
    }
    return fallback;
  }
}

final class _BackendDisposedException implements Exception {
  const _BackendDisposedException();
}

final class _SingleDigestSink implements Sink<Digest> {
  Digest? _digest;

  Digest get value => _digest!;

  @override
  void add(Digest data) {
    _digest = data;
  }

  @override
  void close() {}
}
