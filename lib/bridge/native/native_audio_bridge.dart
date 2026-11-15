/// Native FFI implementation of all 5 Middle Bridge audio contracts backed by
/// Layer 1–3 C/C++ (`muse_engine_bindings.g.dart`) and `IInternalStorageLocator`.
library;

import 'dart:async';
import 'dart:convert';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

import '../contracts/audio_bridge_contracts.dart';
import '../contracts/engine_constants.dart';
import '../contracts/ids_and_units.dart';
import '../contracts/result.dart';
import 'muse_engine_bindings.g.dart';
import 'platform_audio_permission.dart';

enum _NativeLifecyclePhase {
  uninitialized,
  initializing,
  ready,
  disposing,
  disposed,
}

enum _BridgeOpContext {
  lifecycle,
  soundFontNative,
  transport,
  synthEvent,
  recording,
  takePlayback,
}

/// Native FFI audio engine bridge implementing lifecycle, transport, synth
/// event scheduling, capture recording, and single-consumer telemetry contracts.
final class NativeAudioBridge
    implements
        IAudioLifecycleBridge,
        ITransportBridge,
        ISynthEventBridge,
        IRecordingBridge,
        ITelemetryBridge {
  static const String _sf2Extension = 'sf2';
  static const String _wavExtension = 'wav';
  static const int _initialEpochValue = 0;
  static const int _byteMask = 0xFF;

  final IInternalStorageLocator _storageLocator;
  final INativeAudioPermissionChecker _permissionChecker;

  MuseEngineHandle _engine = ffi.nullptr;
  AudioHardwareInfo? _hardwareInfo;
  EpochId _currentEpoch = const EpochId(_initialEpochValue);
  TelemetrySnapshot? _latestSnapshot;
  _NativeLifecyclePhase _phase = _NativeLifecyclePhase.uninitialized;

  int _inFlightAsyncOps = 0;
  Completer<void>? _drainCompleter;
  Completer<void>? _disposeCompleter;

  /// Creates a native FFI audio bridge using [storageLocator] for CAS/staging
  /// path resolution and optional [permissionChecker] for runtime mic checks.
  NativeAudioBridge({
    required this._storageLocator,
    INativeAudioPermissionChecker? permissionChecker,
    bool isAndroidOverride = false,
  }) : _permissionChecker =
           permissionChecker ??
           PlatformAudioPermissionChecker(
             isAndroidOverride: isAndroidOverride ? true : null,
           );

  // ---------------------------------------------------------------------------
  // IAudioLifecycleBridge
  // ---------------------------------------------------------------------------

  @override
  AudioHardwareInfo get currentHardwareInfo {
    final info = _hardwareInfo;
    if (info == null || _phase != _NativeLifecyclePhase.ready) {
      throw StateError('Audio engine is not initialized.');
    }
    return info;
  }

  @override
  Future<Result<AudioHardwareInfo>> initialize() async {
    if (_phase != _NativeLifecyclePhase.uninitialized) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Audio engine initialize() called in an invalid lifecycle state.',
        ),
      );
    }

    _phase = _NativeLifecyclePhase.initializing;

    final permissionResult = await _permissionChecker
        .ensureMicrophonePermission();
    if (_phase != _NativeLifecyclePhase.initializing) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Audio engine was disposed while checking microphone permission.',
        ),
      );
    }
    if (permissionResult case Err<void>(:final error)) {
      _phase = _NativeLifecyclePhase.uninitialized;
      return Err(error);
    }

    final outEngine = calloc<MuseEngineHandle>();
    final outConfig = calloc<MuseHardwareConfig>();
    try {
      final status = muse_engine_create(outEngine, outConfig);
      if (status != MUSE_OK || outEngine.value == ffi.nullptr) {
        _phase = _NativeLifecyclePhase.uninitialized;
        return Err(
          _mapStatus(
            status == MUSE_OK ? MUSE_ERR_DEVICE_INIT : status,
            context: _BridgeOpContext.lifecycle,
          ),
        );
      }

      final cfg = outConfig.ref;
      if (cfg.sample_rate <= 0 || cfg.output_channels <= 0) {
        muse_engine_destroy(outEngine.value);
        _phase = _NativeLifecyclePhase.uninitialized;
        return const Err(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Native HAL negotiated invalid sample rate or channel count.',
          ),
        );
      }

      final fingerprint = _decodeCStringArray(
        cfg.device_fingerprint,
        kDeviceFingerprintBufferSize,
        allowMalformed: false,
      );
      if (fingerprint.isEmpty) {
        muse_engine_destroy(outEngine.value);
        _phase = _NativeLifecyclePhase.uninitialized;
        return const Err(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Native HAL returned an empty device fingerprint.',
          ),
        );
      }

      final info = AudioHardwareInfo(
        sampleRate: cfg.sample_rate,
        inputChannels: cfg.input_channels,
        outputChannels: cfg.output_channels,
        inputBufferFrames: cfg.input_buffer_frames,
        outputBufferFrames: cfg.output_buffer_frames,
        deviceFingerprint: fingerprint,
      );

      _engine = outEngine.value;
      _hardwareInfo = info;
      _currentEpoch = const EpochId(_initialEpochValue);
      _latestSnapshot = null;
      _phase = _NativeLifecyclePhase.ready;
      return Ok(info);
    } finally {
      calloc.free(outEngine);
      calloc.free(outConfig);
    }
  }

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  }) async {
    final readyCheck = _requireReadyEngine<LoadedSoundFontDescriptor>(
      MuseErrorCode.soundFontLoadFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }

    final posixPath = _storageLocator.resolveNativeCasPosixPath(
      sha256,
      ext: _sf2Extension,
    );
    if (posixPath == null ||
        posixPath.isEmpty ||
        !File(posixPath).existsSync()) {
      return Err(
        MuseError(
          MuseErrorCode.casBlobMissing,
          'SoundFont CAS blob is missing on disk for ${sha256.value}.',
        ),
      );
    }

    final outcome = await _runBlockingEngineCall((engineAddress) {
      final engine = MuseEngineHandle.fromAddress(engineAddress);
      final pathPtr = posixPath.toNativeUtf8(allocator: calloc).cast<ffi.Char>();
      final outSfHandle = calloc<ffi.Int32>();
      final outPresets = calloc<MuseSoundFontPresetPod>(
        MuseConstants.maxSoundFontPresets,
      );
      final outPresetCount = calloc<ffi.Uint32>();
      try {
        final status = muse_engine_load_sf2_file(
          engine,
          pathPtr,
          outSfHandle,
          outPresets,
          MuseConstants.maxSoundFontPresets,
          outPresetCount,
        );
        if (status != MUSE_OK) {
          return _NativeSfLoadResult.err(status);
        }

        final presetCount = outPresetCount.value;
        if (presetCount > MuseConstants.maxSoundFontPresets) {
          return const _NativeSfLoadResult.err(MUSE_ERR_BUFFER_TOO_SMALL);
        }

        final presets = <SoundFontPresetInfo>[
          for (var i = 0; i < presetCount; i++)
            SoundFontPresetInfo(
              bankNum: outPresets[i].bank_num,
              programNum: outPresets[i].program_num,
              presetName: _decodeCStringArray(
                outPresets[i].preset_name,
                kPresetNameBufferSize,
                allowMalformed: true,
              ),
            ),
        ];

        return _NativeSfLoadResult.ok(
          sfHandle: outSfHandle.value,
          presets: List<SoundFontPresetInfo>.unmodifiable(presets),
        );
      } finally {
        calloc.free(pathPtr);
        calloc.free(outSfHandle);
        calloc.free(outPresets);
        calloc.free(outPresetCount);
      }
    });

    if (outcome == null) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'Audio engine is disposed or unavailable.',
        ),
      );
    }
    if (outcome.status != MUSE_OK) {
      return Err(
        _mapStatus(
          outcome.status,
          context: _BridgeOpContext.soundFontNative,
        ),
      );
    }
    if (outcome.sfHandle <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'FluidSynth returned an invalid SoundFont handle.',
        ),
      );
    }
    return Ok(
      LoadedSoundFontDescriptor(
        handle: SoundFontHandle(outcome.sfHandle),
        presets: outcome.presets,
      ),
    );
  }

  @override
  Future<Result<void>> unloadSoundFont(SoundFontHandle handle) async {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.soundFontLoadFailed,
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

    final handleValue = handle.value;
    final status = await _runBlockingEngineCall((engineAddress) {
      final engine = MuseEngineHandle.fromAddress(engineAddress);
      return muse_engine_unload_sf2(engine, handleValue);
    });
    if (status == null) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'Audio engine is disposed or unavailable.',
        ),
      );
    }
    if (status != MUSE_OK) {
      return Err(
        _mapStatus(status, context: _BridgeOpContext.soundFontNative),
      );
    }
    return const Ok(null);
  }

  @override
  Future<void> dispose() async {
    if (_phase == _NativeLifecyclePhase.disposed) {
      return;
    }
    if (_phase == _NativeLifecyclePhase.disposing) {
      await _disposeCompleter?.future;
      return;
    }

    _phase = _NativeLifecyclePhase.disposing;
    final disposeCompleter = Completer<void>();
    _disposeCompleter = disposeCompleter;

    try {
      // Wait for Isolate.run FFI workers before freeing the native C++ handle.
      if (_inFlightAsyncOps > 0) {
        final drainCompleter = _drainCompleter ??= Completer<void>();
        await drainCompleter.future;
      }

      if (_engine != ffi.nullptr) {
        muse_engine_destroy(_engine);
        _engine = ffi.nullptr;
      }
      _hardwareInfo = null;
      _latestSnapshot = null;
      _phase = _NativeLifecyclePhase.disposed;
    } finally {
      if (!disposeCompleter.isCompleted) {
        disposeCompleter.complete();
      }
    }
  }

  // ---------------------------------------------------------------------------
  // ITransportBridge
  // ---------------------------------------------------------------------------

  @override
  Result<void> play() {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    return _pushMutation(
      type: MUT_SET_PLAYING,
      flagA: 1,
      context: _BridgeOpContext.transport,
    );
  }

  @override
  Result<void> pause() {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    return _pushMutation(
      type: MUT_SET_PLAYING,
      flagA: 0,
      context: _BridgeOpContext.transport,
    );
  }

  @override
  Result<void> stop() {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }

    final pauseResult = _pushMutation(
      type: MUT_SET_PLAYING,
      flagA: 0,
      context: _BridgeOpContext.transport,
    );
    if (pauseResult case Err<void>(:final error)) {
      return Err(error);
    }

    final nextEpoch = EpochId(_currentEpoch.value + 1);
    final seekResult = _pushMutation(
      type: MUT_SEEK_SAMPLE,
      targetEpoch: nextEpoch.value,
      sampleFrameA: 0,
      context: _BridgeOpContext.transport,
    );
    if (seekResult case Err<void>(:final error)) {
      return Err(error);
    }

    // Advance cached epoch only after both FFI queue pushes succeed.
    _currentEpoch = nextEpoch;
    return const Ok(null);
  }

  @override
  Result<EpochId> seekToSample(SampleFrame targetFrame) {
    final readyCheck = _requireReadyEngine<EpochId>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (targetFrame.value < 0) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Seek sample frame must be non-negative.',
        ),
      );
    }

    final nextEpoch = EpochId(_currentEpoch.value + 1);
    final pushResult = _pushMutation(
      type: MUT_SEEK_SAMPLE,
      targetEpoch: nextEpoch.value,
      sampleFrameA: targetFrame.value,
      context: _BridgeOpContext.transport,
    );
    if (pushResult case Err<void>(:final error)) {
      return Err(error);
    }

    _currentEpoch = nextEpoch;
    return Ok(_currentEpoch);
  }

  @override
  Result<void> setLoopRegion({
    required bool enabled,
    required SampleFrame startFrame,
    required SampleFrame endFrame,
  }) {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (startFrame.value < 0 || (enabled && endFrame.value <= startFrame.value)) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Loop region requires startFrame >= 0 and endFrame > startFrame when enabled.',
        ),
      );
    }

    return _pushMutation(
      type: MUT_SET_LOOP_REGION,
      flagA: enabled ? 1 : 0,
      sampleFrameA: startFrame.value,
      sampleFrameB: endFrame.value,
      context: _BridgeOpContext.transport,
    );
  }

  @override
  Future<Result<void>> syncActiveTakeRegions(
    List<ActiveTakePlaybackRegion> regions,
  ) async {
    final readyCheck = _requireReadyEngine<void>(MuseErrorCode.takeLoadFailed);
    if (readyCheck != null) {
      return readyCheck;
    }

    if (regions.length > MuseConstants.maxActiveTakeRegions) {
      return Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Active take count (${regions.length}) exceeds limit '
          '(${MuseConstants.maxActiveTakeRegions}).',
        ),
      );
    }

    final resolvedTakes = <_ResolvedTakeRegistration>[];
    for (final region in regions) {
      if (region.takeId.value.isEmpty ||
          utf8.encode(region.takeId.value).length >= kTakeIdBufferSize ||
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

      final wavPath = _storageLocator.resolveNativeCasPosixPath(
        region.wavSha256,
        ext: _wavExtension,
      );
      if (wavPath == null ||
          wavPath.isEmpty ||
          utf8.encode(wavPath).length >= kCasPathBufferSize ||
          !File(wavPath).existsSync()) {
        return Err(
          MuseError(
            MuseErrorCode.casBlobMissing,
            'Take WAV CAS blob is missing on disk for ${region.wavSha256.value}.',
          ),
        );
      }

      resolvedTakes.add(
        _ResolvedTakeRegistration(
          takeId: region.takeId.value,
          wavPosixPath: wavPath,
          startSampleFrame: region.startSampleFrame.value,
          durationFrames: region.durationFrames,
          gainDb: region.gainDb,
          pan: region.pan,
        ),
      );
    }

    final status = await _runBlockingEngineCall((engineAddress) {
      final engine = MuseEngineHandle.fromAddress(engineAddress);
      final clearStatus = muse_engine_clear_active_takes(engine);
      if (clearStatus != MUSE_OK) {
        return clearStatus;
      }

      for (final take in resolvedTakes) {
        final idPtr = take.takeId.toNativeUtf8(allocator: calloc).cast<ffi.Char>();
        final pathPtr = take.wavPosixPath
            .toNativeUtf8(allocator: calloc)
            .cast<ffi.Char>();
        try {
          final regStatus = muse_engine_register_active_take(
            engine,
            idPtr,
            pathPtr,
            take.startSampleFrame,
            take.durationFrames,
            take.gainDb,
            take.pan,
          );
          if (regStatus != MUSE_OK) {
            // Roll back partial registrations so stale partial state never plays.
            muse_engine_clear_active_takes(engine);
            return regStatus;
          }
        } finally {
          calloc.free(idPtr);
          calloc.free(pathPtr);
        }
      }
      return MUSE_OK;
    });

    if (status == null) {
      return const Err(
        MuseError(
          MuseErrorCode.takeLoadFailed,
          'Audio engine is disposed or unavailable.',
        ),
      );
    }
    if (status != MUSE_OK) {
      return Err(_mapStatus(status, context: _BridgeOpContext.takePlayback));
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
    final readyCheck = _requireReadyEngine<EpochId>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }

    final nextEpoch = EpochId(_currentEpoch.value + 1);
    final pushResult = _pushMutation(
      type: MUT_FLUSH_AND_ADVANCE_EPOCH,
      targetEpoch: nextEpoch.value,
      context: _BridgeOpContext.synthEvent,
    );
    if (pushResult case Err<void>(:final error)) {
      return Err(error);
    }

    _currentEpoch = nextEpoch;
    return Ok(_currentEpoch);
  }

  @override
  Result<int> scheduleEvents(
    List<ScheduledMidiEvent> events, {
    SampleFrame? scheduledUpToFrame,
  }) {
    final readyCheck = _requireReadyEngine<int>(
      MuseErrorCode.eventQueueOverflow,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (scheduledUpToFrame != null && scheduledUpToFrame.value < 0) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'Scheduled watermark frame must be non-negative.',
        ),
      );
    }
    if (events.isEmpty) {
      if (scheduledUpToFrame == null) {
        return const Ok(0);
      }
      final watermarkResult = _pushMutation(
        type: MUT_SET_SCHEDULED_WATERMARK,
        targetEpoch: _currentEpoch.value,
        sampleFrameA: scheduledUpToFrame.value,
        context: _BridgeOpContext.synthEvent,
      );
      if (watermarkResult case Err<void>(:final error)) {
        return Err(error);
      }
      return const Ok(0);
    }

    for (final evt in events) {
      if (evt.type < MuseConstants.midiEventNoteOn ||
          evt.type > MuseConstants.midiEventPitchBend ||
          !_isValidMidiChannel(evt.channel) ||
          !_isValidSevenBitMidiValue(evt.data1) ||
          !_isValidSevenBitMidiValue(evt.data2) ||
          evt.pitchBend < kMinPitchBendSigned ||
          evt.pitchBend > kMaxPitchBendSigned ||
          evt.epoch.value < 0 ||
          (evt.targetSampleFrame.value != MuseConstants.immediateDispatchFrame &&
              evt.targetSampleFrame.value < 0)) {
        return const Err(
          MuseError(
            MuseErrorCode.invalidMidiChannelOrPitch,
            'ScheduledMidiEvent contains out-of-range type, channel, data, pitch bend, or sample frame.',
          ),
        );
      }
    }

    final nativeEvents = calloc<SynthNoteEvent>(events.length);
    final outPushedCount = calloc<ffi.Uint32>();
    try {
      for (var i = 0; i < events.length; i++) {
        final src = events[i];
        final dst = nativeEvents[i];
        dst.epoch = src.epoch.value;
        dst.target_sample_frame = src.targetSampleFrame.value;
        dst.type = src.type;
        dst.channel = src.channel;
        dst.key_or_cc = src.data1;
        dst.velocity_or_val = src.data2;
        dst.pitch_bend = src.pitchBend;
        dst.reserved = src.loopPass & 0xFFFF;
      }

      final status = muse_engine_push_events(
        _engine,
        nativeEvents,
        events.length,
        outPushedCount,
      );
      final pushedCount = outPushedCount.value;

      var hasTimelineWatermark = false;
      var maxTimelineFrame = 0;
      if (status == MUSE_OK && scheduledUpToFrame != null) {
        hasTimelineWatermark = true;
        maxTimelineFrame = scheduledUpToFrame.value;
      } else {
        for (var i = 0; i < pushedCount && i < events.length; i++) {
          final evt = events[i];
          if (evt.epoch.value == _currentEpoch.value &&
              evt.targetSampleFrame.value !=
                  MuseConstants.immediateDispatchFrame) {
            if (!hasTimelineWatermark ||
                evt.targetSampleFrame.value > maxTimelineFrame) {
              maxTimelineFrame = evt.targetSampleFrame.value;
              hasTimelineWatermark = true;
            }
          }
        }
      }

      if (hasTimelineWatermark) {
        final watermarkResult = _pushMutation(
          type: MUT_SET_SCHEDULED_WATERMARK,
          targetEpoch: _currentEpoch.value,
          sampleFrameA: maxTimelineFrame,
          context: _BridgeOpContext.synthEvent,
        );
        if (status == MUSE_OK) {
          if (watermarkResult case Err<void>(:final error)) {
            return Err(error);
          }
        }
      }

      if (status != MUSE_OK) {
        return Err(_mapStatus(status, context: _BridgeOpContext.synthEvent));
      }
      return Ok(pushedCount);
    } finally {
      calloc.free(nativeEvents);
      calloc.free(outPushedCount);
    }
  }

  @override
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  }) {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.soundFontLoadFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (!_isValidMidiChannel(midiChannel) ||
        bankNum < MuseConstants.minBankNum ||
        bankNum > MuseConstants.maxBankNum ||
        programNum < MuseConstants.minProgramNum ||
        programNum > MuseConstants.maxProgramNum) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'MIDI channel, bank, or program index is out of range.',
        ),
      );
    }
    if (sfHandle.value <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'SoundFontHandle must be positive.',
        ),
      );
    }

    return _pushMutation(
      type: MUT_ASSIGN_CHANNEL_PATCH,
      channel: midiChannel,
      intParamA: sfHandle.value,
      intParamB: bankNum,
      intParamC: programNum,
      context: _BridgeOpContext.soundFontNative,
    );
  }

  @override
  Result<void> setChannelMix({
    required int midiChannel,
    required double gainDb,
    required double pan,
  }) {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (!_isValidMidiChannel(midiChannel) || !gainDb.isFinite || !pan.isFinite) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'setChannelMix requires valid MIDI channel and finite gain/pan.',
        ),
      );
    }

    return _pushMutation(
      type: MUT_SET_CHANNEL_MIX,
      channel: midiChannel,
      floatParamA: gainDb,
      floatParamB: pan,
      context: _BridgeOpContext.synthEvent,
    );
  }

  @override
  Result<void> silenceChannel(int midiChannel) {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (!_isValidMidiChannel(midiChannel)) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'MIDI channel must be within 0..15.',
        ),
      );
    }

    return _pushMutation(
      type: MUT_ALL_NOTES_OFF_CHANNEL,
      channel: midiChannel,
      context: _BridgeOpContext.synthEvent,
    );
  }

  @override
  Result<void> triggerLiveAuditionNote({
    required int midiChannel,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.eventQueueOverflow,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (!_isValidMidiChannel(midiChannel) ||
        !_isValidSevenBitMidiValue(pitchMidi) ||
        !_isValidSevenBitMidiValue(velocity)) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'Live audition note requires channel 0..15 and pitch/velocity 0..127.',
        ),
      );
    }

    final eventPtr = calloc<SynthNoteEvent>();
    final outPushedCount = calloc<ffi.Uint32>();
    try {
      final evt = eventPtr.ref;
      evt.epoch = _currentEpoch.value;
      // Audition uses sentinel immediateDispatchFrame so paused transport still renders notes.
      evt.target_sample_frame = MuseConstants.immediateDispatchFrame;
      evt.type = (isNoteOn && velocity > 0)
          ? MuseConstants.midiEventNoteOn
          : MuseConstants.midiEventNoteOff;
      evt.channel = midiChannel;
      evt.key_or_cc = pitchMidi;
      evt.velocity_or_val = isNoteOn ? velocity : 0;
      evt.pitch_bend = MuseConstants.neutralPitchBend;
      evt.reserved = 0;

      final status = muse_engine_push_events(_engine, eventPtr, 1, outPushedCount);
      if (status != MUSE_OK) {
        return Err(_mapStatus(status, context: _BridgeOpContext.synthEvent));
      }
      return const Ok(null);
    } finally {
      calloc.free(eventPtr);
      calloc.free(outPushedCount);
    }
  }

  // ---------------------------------------------------------------------------
  // IRecordingBridge
  // ---------------------------------------------------------------------------

  @override
  Result<void> setMonitorGain(double gainLinear) {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
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

    return _pushMutation(
      type: MUT_SET_MONITOR_GAIN,
      floatParamA: gainLinear,
      context: _BridgeOpContext.recording,
    );
  }

  @override
  Future<Result<void>> prepareAndStartCapture(TakeId takeId) async {
    final readyCheck = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (takeId.value.isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'TakeId must not be empty when starting capture.',
        ),
      );
    }

    final permissionResult = await _permissionChecker
        .ensureMicrophonePermission();
    if (permissionResult case Err<void>(:final error)) {
      return Err(error);
    }

    final postPermissionReady = _requireReadyEngine<void>(
      MuseErrorCode.audioDeviceInitFailed,
    );
    if (postPermissionReady != null) {
      return postPermissionReady;
    }

    final stagingPath = _storageLocator.resolveRecordingStagingPath(takeId);
    if (stagingPath.isEmpty ||
        utf8.encode(stagingPath).length >= kStagingPathBufferSize) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Resolved recording staging path is empty or exceeds buffer limit.',
        ),
      );
    }

    try {
      await Directory(p.dirname(stagingPath)).create(recursive: true);
    } on FileSystemException catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Failed to create staging directory for recording capture.',
          cause: error,
        ),
      );
    }

    final status = await _runBlockingEngineCall((engineAddress) {
      final engine = MuseEngineHandle.fromAddress(engineAddress);
      final pathPtr = stagingPath
          .toNativeUtf8(allocator: calloc)
          .cast<ffi.Char>();
      try {
        final prepareStatus = muse_engine_prepare_capture(engine, pathPtr);
        if (prepareStatus != MUSE_OK) {
          return prepareStatus;
        }
        return muse_engine_start_capture(engine);
      } finally {
        calloc.free(pathPtr);
      }
    });

    if (status == null) {
      return const Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Audio engine is disposed or unavailable.',
        ),
      );
    }
    if (status != MUSE_OK) {
      return Err(_mapStatus(status, context: _BridgeOpContext.recording));
    }
    return const Ok(null);
  }

  @override
  Future<Result<RecordingCaptureReceipt>> stopAndFinalizeCapture(
    TakeId takeId,
  ) async {
    final readyCheck = _requireReadyEngine<RecordingCaptureReceipt>(
      MuseErrorCode.casPromotionFailed,
    );
    if (readyCheck != null) {
      return readyCheck;
    }
    if (takeId.value.isEmpty) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'TakeId must not be empty when finalizing capture.',
        ),
      );
    }

    final outcome = await _runBlockingEngineCall((engineAddress) {
      final engine = MuseEngineHandle.fromAddress(engineAddress);
      final receiptPtr = calloc<FinalizedCaptureReceipt>();
      try {
        final callStatus = muse_engine_stop_and_finalize_capture(
          engine,
          receiptPtr,
        );
        final receipt = receiptPtr.ref;
        final receiptStatus = receipt.status;
        if (callStatus != MUSE_OK || receiptStatus != MUSE_OK) {
          final effectiveStatus = (receiptStatus == MUSE_ERR_CAPTURE_OVERFLOW ||
                  callStatus == MUSE_ERR_CAPTURE_OVERFLOW)
              ? MUSE_ERR_CAPTURE_OVERFLOW
              : (receiptStatus != MUSE_OK ? receiptStatus : callStatus);
          return _NativeCaptureResult.err(effectiveStatus);
        }

        final stagingPath = _decodeCStringArray(
          receipt.staging_path,
          kStagingPathBufferSize,
          allowMalformed: false,
        );
        final sha256Hex = _decodeCStringArray(
          receipt.sha256_hex,
          kSha256HexBufferSize,
          allowMalformed: false,
        );

        return _NativeCaptureResult.ok(
          stagingPath: stagingPath,
          sha256Hex: sha256Hex,
          capturedSampleClock: receipt.captured_sample_clock,
          capturedPlayheadFrame: receipt.captured_playhead_frame,
          durationFrames: receipt.duration_frames,
          sampleRate: receipt.sample_rate,
          channelCount: receipt.channel_count,
          outputBufferFrames: receipt.output_buffer_frames,
          inputBufferFrames: receipt.input_buffer_frames,
        );
      } finally {
        calloc.free(receiptPtr);
      }
    });

    if (outcome == null) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Audio engine is disposed or unavailable.',
        ),
      );
    }
    if (outcome.status != MUSE_OK) {
      return Err(
        _mapStatus(outcome.status, context: _BridgeOpContext.recording),
      );
    }

    if (outcome.durationFrames < 0 ||
        outcome.sha256Hex.length != kSha256HexLength ||
        outcome.stagingPath.isEmpty ||
        outcome.sampleRate <= 0 ||
        outcome.channelCount <= 0) {
      return const Err(
        MuseError(
          MuseErrorCode.casPromotionFailed,
          'Native capture finalization produced malformed receipt metadata.',
        ),
      );
    }

    return Ok(
      RecordingCaptureReceipt(
        takeId: takeId,
        stagingPath: outcome.stagingPath,
        sha256: Sha256Digest(outcome.sha256Hex),
        capturedSampleClock: SampleFrame(outcome.capturedSampleClock),
        capturedPlayheadFrame: SampleFrame(outcome.capturedPlayheadFrame),
        durationFrames: outcome.durationFrames,
        sampleRate: outcome.sampleRate,
        channelCount: outcome.channelCount,
        outputBufferFrames: outcome.outputBufferFrames,
        inputBufferFrames: outcome.inputBufferFrames,
      ),
    );
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
    if (maxFrames <= 0) {
      throw ArgumentError.value(maxFrames, 'maxFrames', 'Must be positive.');
    }
    if (_phase != _NativeLifecyclePhase.ready || _engine == ffi.nullptr) {
      return const <TelemetrySnapshot>[];
    }

    final boundedFrames = math.min(maxFrames, kTelemetryQueueCapacity);
    final outFrames = calloc<TelemetryFrame>(boundedFrames);
    try {
      final count = muse_engine_drain_telemetry(
        _engine,
        outFrames,
        boundedFrames,
      );
      if (count == 0) {
        return const <TelemetrySnapshot>[];
      }

      final clampedCount = math.min(count, boundedFrames);
      final snapshots = <TelemetrySnapshot>[
        for (var i = 0; i < clampedCount; i++)
          TelemetrySnapshot(
            playheadSampleFrame: SampleFrame(outFrames[i].playhead_sample_frame),
            activeEpoch: EpochId(outFrames[i].active_epoch),
            outputPeakL: outFrames[i].output_peak_l,
            outputPeakR: outFrames[i].output_peak_r,
            outputRmsL: outFrames[i].output_rms_l,
            outputRmsR: outFrames[i].output_rms_r,
            inputPeak: outFrames[i].input_peak,
            inputRms: outFrames[i].input_rms,
            isPlaying: outFrames[i].is_playing != 0,
            isCapturing: outFrames[i].is_capturing != 0,
            hasEventQueueUnderrun: outFrames[i].event_queue_underrun != 0,
            hasCaptureBufferOverflow: outFrames[i].capture_buffer_overflow != 0,
            hasTakePlaybackUnderrun: outFrames[i].take_playback_underrun != 0,
            loopPass:
                outFrames[i].reserved[0] | (outFrames[i].reserved[1] << 8),
          ),
      ];

      _latestSnapshot = snapshots.last;
      return List<TelemetrySnapshot>.unmodifiable(snapshots);
    } finally {
      calloc.free(outFrames);
    }
  }

  // ---------------------------------------------------------------------------
  // Internal Helpers & Error Translation
  // ---------------------------------------------------------------------------

  Err<T>? _requireReadyEngine<T>(MuseErrorCode code) {
    if (_phase != _NativeLifecyclePhase.ready || _engine == ffi.nullptr) {
      return Err<T>(
        MuseError(code, 'Native audio engine is not ready (phase: $_phase).'),
      );
    }
    return null;
  }

  Future<T?> _runBlockingEngineCall<T>(
    FutureOr<T> Function(int engineAddress) fn,
  ) async {
    if (_phase != _NativeLifecyclePhase.ready || _engine == ffi.nullptr) {
      return null;
    }

    final engineAddress = _engine.address;
    _inFlightAsyncOps++;
    try {
      return await Isolate.run(() => fn(engineAddress));
    } finally {
      _inFlightAsyncOps--;
      if (_inFlightAsyncOps == 0) {
        final drainCompleter = _drainCompleter;
        if (drainCompleter != null && !drainCompleter.isCompleted) {
          drainCompleter.complete();
        }
      }
    }
  }

  Result<void> _pushMutation({
    required int type,
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
    required _BridgeOpContext context,
  }) {
    final cmdPtr = MutationCommand.$allocate(
      calloc,
      type: type,
      channel: channel,
      flag_a: flagA,
      reserved: 0,
      int_param_a: intParamA,
      int_param_b: intParamB,
      int_param_c: intParamC,
      float_param_a: floatParamA,
      float_param_b: floatParamB,
      target_epoch: targetEpoch,
      sample_frame_a: sampleFrameA,
      sample_frame_b: sampleFrameB,
    );
    try {
      final status = muse_engine_push_mutation(_engine, cmdPtr);
      if (status != MUSE_OK) {
        return Err(_mapStatus(status, context: context));
      }
      return const Ok(null);
    } finally {
      calloc.free(cmdPtr);
    }
  }

  MuseError _mapStatus(int status, {required _BridgeOpContext context}) {
    return switch (status) {
      MUSE_ERR_DEVICE_INIT => const MuseError(
        MuseErrorCode.audioDeviceInitFailed,
        'Native audio device initialization or state check failed.',
      ),
      MUSE_ERR_PERMISSION_DENIED => const MuseError(
        MuseErrorCode.microphonePermissionDenied,
        'Microphone capture permission denied by OS HAL.',
      ),
      MUSE_ERR_SF_LOAD_FAILED => const MuseError(
        MuseErrorCode.soundFontLoadFailed,
        'Failed to load or unload SoundFont asset.',
      ),
      MUSE_ERR_SF_TOO_LARGE => context == _BridgeOpContext.soundFontNative
          ? const MuseError(
              MuseErrorCode.soundFontLoadFailed,
              'SoundFont asset exceeded size limits.',
            )
          : const MuseError(
              MuseErrorCode.soundFontTooLargeForWeb,
              'SoundFont exceeds maximum size.',
            ),
      MUSE_ERR_TRANSPORT_NOT_STOPPED => context == _BridgeOpContext.soundFontNative
          ? const MuseError(
              MuseErrorCode.webSoundFontLoadWhilePlaying,
              'SoundFont operation rejected because transport/capture is active.',
            )
          : const MuseError(
              MuseErrorCode.audioDeviceInitFailed,
              'Operation requires stopped transport/capture state.',
            ),
      MUSE_ERR_QUEUE_FULL => switch (context) {
        _BridgeOpContext.synthEvent => const MuseError(
          MuseErrorCode.eventQueueOverflow,
          'Real-time MIDI event or mutation queue is full.',
        ),
        _BridgeOpContext.takePlayback => const MuseError(
          MuseErrorCode.takePlaybackBufferUnderrun,
          'Take playback command queue is full.',
        ),
        _ => const MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Real-time audio mutation queue is full.',
        ),
      },
      MUSE_ERR_CAPTURE_OVERFLOW => const MuseError(
        MuseErrorCode.captureBufferOverflow,
        'Recording CaptureRingBuffer overflowed before Butler drained frames.',
      ),
      MUSE_ERR_STORAGE_IO => const MuseError(
        MuseErrorCode.casPromotionFailed,
        'Native Butler storage I/O or WAV finalization failed.',
      ),
      MUSE_ERR_BUFFER_TOO_SMALL => const MuseError(
        MuseErrorCode.soundFontPresetBufferTooSmall,
        'SoundFont preset count exceeded fixed output buffer.',
      ),
      MUSE_ERR_TAKE_LOAD_FAILED => const MuseError(
        MuseErrorCode.takeLoadFailed,
        'Failed to decode or register active audio take region.',
      ),
      _ => MuseError(
        MuseErrorCode.audioDeviceInitFailed,
        'Unexpected native audio engine status code: $status.',
      ),
    };
  }

  static bool _isValidMidiChannel(int ch) =>
      ch >= MuseConstants.minMidiChannel && ch <= MuseConstants.maxMidiChannel;

  static bool _isValidSevenBitMidiValue(int value) =>
      value >= MuseConstants.minMidiPitch && value <= MuseConstants.maxMidiPitch;

  static String _decodeCStringArray(
    ffi.Array<ffi.Char> buffer,
    int maxLength, {
    required bool allowMalformed,
  }) {
    final bytes = <int>[];
    for (var i = 0; i < maxLength; i++) {
      final rawByte = buffer[i] & _byteMask;
      if (rawByte == 0) {
        break;
      }
      bytes.add(rawByte);
    }
    return utf8.decode(Uint8List.fromList(bytes), allowMalformed: allowMalformed);
  }
}

final class _ResolvedTakeRegistration {
  final String takeId;
  final String wavPosixPath;
  final int startSampleFrame;
  final int durationFrames;
  final double gainDb;
  final double pan;

  const _ResolvedTakeRegistration({
    required this.takeId,
    required this.wavPosixPath,
    required this.startSampleFrame,
    required this.durationFrames,
    required this.gainDb,
    required this.pan,
  });
}

final class _NativeSfLoadResult {
  final int status;
  final int sfHandle;
  final List<SoundFontPresetInfo> presets;

  const _NativeSfLoadResult.ok({
    required this.sfHandle,
    required this.presets,
  }) : status = MUSE_OK;

  const _NativeSfLoadResult.err(this.status)
    : sfHandle = kFluidSynthSfFailed,
      presets = const <SoundFontPresetInfo>[];
}

final class _NativeCaptureResult {
  final int status;
  final String stagingPath;
  final String sha256Hex;
  final int capturedSampleClock;
  final int capturedPlayheadFrame;
  final int durationFrames;
  final int sampleRate;
  final int channelCount;
  final int outputBufferFrames;
  final int inputBufferFrames;

  const _NativeCaptureResult.ok({
    required this.stagingPath,
    required this.sha256Hex,
    required this.capturedSampleClock,
    required this.capturedPlayheadFrame,
    required this.durationFrames,
    required this.sampleRate,
    required this.channelCount,
    required this.outputBufferFrames,
    required this.inputBufferFrames,
  }) : status = MUSE_OK;

  const _NativeCaptureResult.err(this.status)
    : stagingPath = '',
      sha256Hex = '',
      capturedSampleClock = 0,
      capturedPlayheadFrame = 0,
      durationFrames = 0,
      sampleRate = 0,
      channelCount = 0,
      outputBufferFrames = 0,
      inputBufferFrames = 0;
}
