/// Pure Dart L4 recording session coordinator orchestrating pre-flight storage
/// quota checks, GM Ch 9 count-in metronome clicks, duplex WAV capture, latency
/// calibration compensation, CAS promotion, and take realignment.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:uuid/uuid.dart';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../models/score_models.dart';
import '../notation/dual_model_score_service.dart';
import '../playback/lookahead_playback_coordinator.dart';
import '../repositories/storage_contracts.dart';
import '../timeline/tempo_timeline_calculator.dart';

/// Signature for an injectable asynchronous count-in wait hook.
typedef CountInDelayFn = Future<void> Function(Duration duration);

/// Centralized constants for [RecordingSessionCoordinator].
abstract final class RecordingSessionConstants {
  static const int minCountInMeasures = 0;
  static const int defaultCountInMeasures = 1;
  static const int noCalibrationOffsetFrames = 0;
  static const int noteOffVelocity = 0;
  static const int countInClickDurationDenominator = 4;
  static const double minMonitorGainLinear = 0.0;
  static const int minTick = 0;
  static const int initialMapTick = 0;
  static const int defaultTempoUsPerQuarter = 500000;
  static const int defaultTimeSigNumerator = 4;
  static const int defaultTimeSigDenominator = 4;
  static const int minSampleRate = 1;
  static const int minPositiveDurationTicks = 1;
  static const int minClickDurationMicroseconds = 1;
  static const int minBufferFrames = 0;
  static const int firstBeatIndex = 0;
  static const int microsecondsPerSecond = 1000000;
}

/// Pure Dart contract for microphone input monitoring, count-in recording
/// workflows, and latency-calibration realignment of recorded audio takes.
abstract interface class IRecordingSessionCoordinator {
  Result<void> setInputMonitorGain(double gainLinear);

  Future<Result<TakeId>> startRecordingOnPart({
    required PartId partId,
    required Tick countInStartTick,
    int? countInMeasuresOverride,
  });

  Future<Result<AudioTakeEntity>> stopAndCommitRecording();

  Future<Result<List<AudioTakeEntity>>> realignProjectTakesForCalibration({
    required ProjectId projectId,
    required int newCalibrationOffsetFrames,
  });
}

final class _ActiveRecordingSession {
  final TakeId takeId;
  final ProjectId projectId;
  final PartId partId;
  final ScoreWorkspaceState workspaceSnapshot;
  final ({Tick startTick, Tick endTick})? suspendedLoopRange;

  const _ActiveRecordingSession({
    required this.takeId,
    required this.projectId,
    required this.partId,
    required this.workspaceSnapshot,
    required this.suspendedLoopRange,
  });
}

/// Optional serialization wrapper running DB take commits + bus state sync
/// atomically with `ScoreEditingCommandBus` mutations.
typedef SerializedProjectWriteFn =
    Future<T> Function<T>(Future<T> Function() action);

/// Concrete L4 recording session coordinator integrating [ILookaheadPlaybackCoordinator],
/// Phase 3 audio bridges, and Phase 4 storage repositories.
final class RecordingSessionCoordinator
    implements IRecordingSessionCoordinator {
  final CalibrationPlatform _currentPlatform;
  final IStorageMaintenanceRepository _storageMaintenance;
  final IAssetLibraryRepository _assetLibrary;
  final IProjectRepository _projectRepository;
  final IAudioLifecycleBridge _lifecycleBridge;
  final ITransportBridge _transportBridge;
  final ISynthEventBridge _synthEventBridge;
  final IRecordingBridge _recordingBridge;
  final ITelemetryBridge _telemetryBridge;
  final ILookaheadPlaybackCoordinator _playbackCoordinator;
  final ScoreWorkspaceState? Function() _activeWorkspaceProvider;
  final FutureOr<void> Function(AudioTakeEntity take)? _onTakeCommitted;
  final FutureOr<void> Function(List<AudioTakeEntity> takes)? _onTakesRealigned;
  final SerializedProjectWriteFn? _serializedProjectWrite;
  final Future<Result<void>> Function(PartId? partId)?
  _armedPartSuppressionOverride;
  final SoundFontHandle? Function()? _percussionSoundFontProvider;
  final int _countInMeasures;
  final CountInDelayFn _countInDelay;
  final Uuid _uuid;

  _ActiveRecordingSession? _activeSession;
  bool _isStartingSession = false;

  RecordingSessionCoordinator({
    required this._currentPlatform,
    required this._storageMaintenance,
    required this._assetLibrary,
    required this._projectRepository,
    required this._lifecycleBridge,
    required this._transportBridge,
    required this._synthEventBridge,
    required this._recordingBridge,
    required this._telemetryBridge,
    required this._playbackCoordinator,
    required this._activeWorkspaceProvider,
    this._onTakeCommitted,
    this._onTakesRealigned,
    this._serializedProjectWrite,
    this._armedPartSuppressionOverride,
    this._percussionSoundFontProvider,
    int countInMeasures = RecordingSessionConstants.defaultCountInMeasures,
    CountInDelayFn? countInDelay,
    this._uuid = const Uuid(),
  }) : _countInMeasures = countInMeasures,
       _countInDelay = countInDelay ?? Future<void>.delayed {
    if (countInMeasures < RecordingSessionConstants.minCountInMeasures) {
      throw ArgumentError.value(
        countInMeasures,
        'countInMeasures',
        'Must be >= ${RecordingSessionConstants.minCountInMeasures}',
      );
    }
  }

  @override
  Result<void> setInputMonitorGain(double gainLinear) {
    if (!gainLinear.isFinite ||
        gainLinear < RecordingSessionConstants.minMonitorGainLinear) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Input monitor gain must be finite and non-negative.',
        ),
      );
    }
    return _recordingBridge.setMonitorGain(gainLinear);
  }

  @override
  Future<Result<TakeId>> startRecordingOnPart({
    required PartId partId,
    required Tick countInStartTick,
    int? countInMeasuresOverride,
  }) async {
    if (countInStartTick.value < RecordingSessionConstants.minTick) {
      return Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'countInStartTick (${countInStartTick.value}) must be non-negative.',
        ),
      );
    }
    final effectiveCountInMeasures = countInMeasuresOverride ?? _countInMeasures;
    if (effectiveCountInMeasures <
        RecordingSessionConstants.minCountInMeasures) {
      return Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'countInMeasuresOverride ($effectiveCountInMeasures) must be non-negative.',
        ),
      );
    }
    if (_isStartingSession ||
        _activeSession != null ||
        (_telemetryBridge.latestSnapshot?.isCapturing ?? false)) {
      return const Err(
        MuseError(
          MuseErrorCode.captureBufferOverflow,
          'A recording capture session is already active or starting.',
        ),
      );
    }

    final workspace = _activeWorkspaceProvider();
    if (workspace == null) {
      return const Err(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Cannot start recording: no active project workspace is loaded.',
        ),
      );
    }
    final partExists = workspace.aggregate.parts.any(
      (part) => part.partId == partId,
    );
    if (!partExists) {
      return Err(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Cannot start recording: part "${partId.value}" was not found.',
        ),
      );
    }

    final hwResult = _readHardwareInfo();
    if (hwResult case Err<AudioHardwareInfo>(:final error)) {
      return Err(error);
    }
    final hwInfo = (hwResult as Ok<AudioHardwareInfo>).value;

    _isStartingSession = true;
    var suppressionApplied = false;
    ({Tick startTick, Tick endTick})? suspendedLoopRange;
    var sessionActivated = false;
    try {
      final quotaResult = await _storageMaintenance.verifyAvailableQuotaBytes(
        requiredBytes: MuseConstants.minRecordingFreeQuotaBytes,
      );
      if (quotaResult case Err<int>(:final error)) {
        return Err(error);
      }

      if (_playbackCoordinator.isPlaying) {
        final pauseRes = _playbackCoordinator.pause();
        if (pauseRes case Err<void>(:final error)) {
          return Err(error);
        }
      }

      if (_playbackCoordinator.isLoopEnabled) {
        suspendedLoopRange = _playbackCoordinator.loopTickRange;
        final disableLoopResult = _playbackCoordinator.setLoopTickRange(
          enabled: false,
          startTick: const Tick(RecordingSessionConstants.minTick),
          endTick: const Tick(RecordingSessionConstants.minTick),
        );
        if (disableLoopResult case Err<void>(:final error)) {
          suspendedLoopRange = null;
          return Err(error);
        }
      }

      final suppressResult = await _setArmedPartSuppression(partId);
      if (suppressResult case Err<void>(:final error)) {
        return Err(error);
      }
      suppressionApplied = true;

      if (effectiveCountInMeasures > 0) {
        final countInResult = await _runCountInMetronome(
          aggregate: workspace.aggregate,
          countInStartTick: countInStartTick,
          sampleRate: hwInfo.sampleRate,
          countInMeasures: effectiveCountInMeasures,
        );
        if (countInResult case Err<void>(:final error)) {
          return Err(error);
        }
      }

      final seekResult = _playbackCoordinator.seekToTick(countInStartTick);
      if (seekResult case Err<void>(:final error)) {
        return Err(error);
      }

      final takeId = TakeId(_uuid.v7());
      final captureResult = await _recordingBridge.prepareAndStartCapture(
        takeId,
      );
      if (captureResult case Err<void>(:final error)) {
        return Err(error);
      }

      final playResult = await _playbackCoordinator.play();
      if (playResult case Err<void>(:final error)) {
        await _recordingBridge.stopAndFinalizeCapture(takeId);
        return Err(error);
      }

      _activeSession = _ActiveRecordingSession(
        takeId: takeId,
        projectId: workspace.aggregate.project.projectId,
        partId: partId,
        workspaceSnapshot: workspace,
        suspendedLoopRange: suspendedLoopRange,
      );
      sessionActivated = true;
      return Ok(takeId);
    } finally {
      _isStartingSession = false;
      if (!sessionActivated) {
        if (suppressionApplied) {
          await _setArmedPartSuppression(null);
        }
        if (suspendedLoopRange != null) {
          _playbackCoordinator.setLoopTickRange(
            enabled: true,
            startTick: suspendedLoopRange.startTick,
            endTick: suspendedLoopRange.endTick,
          );
        }
      }
    }
  }

  @override
  Future<Result<AudioTakeEntity>> stopAndCommitRecording() async {
    final session = _activeSession;
    if (session == null) {
      return const Err(
        MuseError(
          MuseErrorCode.entityNotFound,
          'No active recording session is running.',
        ),
      );
    }
    _activeSession = null;

    ScoreWorkspaceState? refreshedWorkspaceForTakes;
    try {
      _playbackCoordinator.pause();

      final finalizeResult = await _recordingBridge.stopAndFinalizeCapture(
        session.takeId,
      );
      if (finalizeResult case Err<RecordingCaptureReceipt>(:final error)) {
        return Err(error);
      }
      final receipt = (finalizeResult as Ok<RecordingCaptureReceipt>).value;
      if (receipt.capturedPlayheadFrame.value < 0 ||
          receipt.outputBufferFrames < RecordingSessionConstants.minBufferFrames ||
          receipt.inputBufferFrames < RecordingSessionConstants.minBufferFrames ||
          receipt.sampleRate < RecordingSessionConstants.minSampleRate) {
        return const Err(
          MuseError(
            MuseErrorCode.casPromotionFailed,
            'Recording capture receipt returned negative frame/buffer counts or invalid sampleRate.',
          ),
        );
      }

      final hwResult = _readHardwareInfo();
      if (hwResult case Err<AudioHardwareInfo>(:final error)) {
        return Err(error);
      }
      final hwInfo = (hwResult as Ok<AudioHardwareInfo>).value;

      final calibrationResult = await _assetLibrary.getCalibrationProfile(
        platform: _currentPlatform,
        deviceFingerprint: hwInfo.deviceFingerprint,
        sampleRate: hwInfo.sampleRate,
        bufferSizeFrames: hwInfo.outputBufferFrames,
      );
      if (calibrationResult case Err<LatencyCalibrationProfile?>(:final error)) {
        return Err(error);
      }
      final profile =
          (calibrationResult as Ok<LatencyCalibrationProfile?>).value;
      final calibrationOffsetFrames =
          profile?.calibrationOffsetFrames ??
          RecordingSessionConstants.noCalibrationOffsetFrames;

      final liveWorkspace = _activeWorkspaceProvider();
      final aggregate =
          (liveWorkspace != null &&
              liveWorkspace.aggregate.project.projectId == session.projectId)
          ? liveWorkspace.aggregate
          : session.workspaceSnapshot.aggregate;

      final calculatorResult = _buildTimelineResult(aggregate);
      if (calculatorResult case Err<TempoTimelineCalculator>(:final error)) {
        return Err(error);
      }
      final calculator =
          (calculatorResult as Ok<TempoTimelineCalculator>).value;
      final alignedStartTickResult = _safeComputeAlignedStartTick(
        calculator: calculator,
        capturedPlayheadFrame: receipt.capturedPlayheadFrame,
        outputBufferFrames: receipt.outputBufferFrames,
        inputBufferFrames: receipt.inputBufferFrames,
        calibrationOffsetFrames: calibrationOffsetFrames,
        sampleRate: receipt.sampleRate,
      );
      if (alignedStartTickResult case Err<Tick>(:final error)) {
        return Err(error);
      }
      final alignedStartTick = (alignedStartTickResult as Ok<Tick>).value;

      final commitResult = await _runSerializedWrite(() async {
        final result = await _projectRepository.promoteAndCommitRecordedTake(
          receipt: receipt,
          projectId: session.projectId,
          partId: session.partId,
          alignedStartTick: alignedStartTick,
          calibrationOffsetFrames: calibrationOffsetFrames,
        );
        if (result case Ok<AudioTakeEntity>(:final value)) {
          await _onTakeCommitted?.call(value);
        }
        return result;
      });
      if (commitResult case Err<AudioTakeEntity>(:final error)) {
        return Err(error);
      }
      final committedTake = (commitResult as Ok<AudioTakeEntity>).value;

      final postCommitWorkspace = _activeWorkspaceProvider();
      if (postCommitWorkspace != null &&
          postCommitWorkspace.aggregate.project.projectId ==
              session.projectId &&
          postCommitWorkspace.aggregate.audioTakes.any(
            (take) => take.takeId == committedTake.takeId,
          )) {
        refreshedWorkspaceForTakes = postCommitWorkspace;
      } else {
        refreshedWorkspaceForTakes = _workspaceWithUpdatedTakes(
          liveWorkspace != null &&
                  liveWorkspace.aggregate.project.projectId == session.projectId
              ? liveWorkspace
              : session.workspaceSnapshot,
          [committedTake],
        );
      }

      return Ok(committedTake);
    } finally {
      await _setArmedPartSuppression(
        null,
        updatedWorkspace: refreshedWorkspaceForTakes,
      );
      if (session.suspendedLoopRange case final savedLoopRange?) {
        _playbackCoordinator.setLoopTickRange(
          enabled: true,
          startTick: savedLoopRange.startTick,
          endTick: savedLoopRange.endTick,
        );
      }
    }
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignProjectTakesForCalibration({
    required ProjectId projectId,
    required int newCalibrationOffsetFrames,
  }) async {
    final ProjectWorkspaceAggregate aggregate;
    final activeWorkspace = _activeWorkspaceProvider();
    if (activeWorkspace != null &&
        activeWorkspace.aggregate.project.projectId == projectId) {
      aggregate = activeWorkspace.aggregate;
    } else {
      final loadResult = await _projectRepository.loadProjectAggregate(
        projectId,
      );
      if (loadResult case Err<ProjectWorkspaceAggregate>(:final error)) {
        return Err(error);
      }
      aggregate = (loadResult as Ok<ProjectWorkspaceAggregate>).value;
    }

    if (aggregate.audioTakes.isEmpty) {
      return const Ok(<AudioTakeEntity>[]);
    }

    final calculatorResult = _buildTimelineResult(aggregate);
    if (calculatorResult case Err<TempoTimelineCalculator>(:final error)) {
      return Err(error);
    }
    final calculator = (calculatorResult as Ok<TempoTimelineCalculator>).value;

    final updates = <AudioTakeRealignmentUpdate>[];
    for (final take in aggregate.audioTakes) {
      if (take.capturedPlayheadFrame.value < 0 ||
          take.outputBufferFrames < RecordingSessionConstants.minBufferFrames ||
          take.inputBufferFrames < RecordingSessionConstants.minBufferFrames ||
          take.sampleRate < RecordingSessionConstants.minSampleRate) {
        return Err(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'AudioTake "${take.takeId.value}" contains invalid capture metrics for realignment.',
          ),
        );
      }
      final newStartTickResult = _safeComputeAlignedStartTick(
        calculator: calculator,
        capturedPlayheadFrame: take.capturedPlayheadFrame,
        outputBufferFrames: take.outputBufferFrames,
        inputBufferFrames: take.inputBufferFrames,
        calibrationOffsetFrames: newCalibrationOffsetFrames,
        sampleRate: take.sampleRate,
      );
      if (newStartTickResult case Err<Tick>(:final error)) {
        return Err(error);
      }
      final newStartTick = (newStartTickResult as Ok<Tick>).value;
      updates.add(
        AudioTakeRealignmentUpdate(
          takeId: take.takeId,
          newStartTick: newStartTick,
          newCalibrationOffsetFrames: newCalibrationOffsetFrames,
        ),
      );
    }

    final realignResult = await _runSerializedWrite(() async {
      final result = await _projectRepository.realignAudioTakesCalibration(
        projectId: projectId,
        updates: updates,
      );
      if (result case Ok<List<AudioTakeEntity>>(:final value)) {
        await _onTakesRealigned?.call(value);
      }
      return result;
    });
    if (realignResult case Err<List<AudioTakeEntity>>(:final error)) {
      return Err(error);
    }
    final realignedTakes = (realignResult as Ok<List<AudioTakeEntity>>).value;

    final latestWorkspace = _activeWorkspaceProvider();
    final updatedWorkspace =
        (latestWorkspace != null &&
            latestWorkspace.aggregate.project.projectId == projectId)
        ? _workspaceWithUpdatedTakes(latestWorkspace, realignedTakes)
        : null;
    await _playbackCoordinator.refreshActiveTakeRegionsIfAttached(
      projectId,
      updatedWorkspace: updatedWorkspace,
    );
    return Ok(realignedTakes);
  }

  // ---------------------------------------------------------------------------
  // Internal Helpers
  // ---------------------------------------------------------------------------

  Result<AudioHardwareInfo> _readHardwareInfo() {
    try {
      final info = _lifecycleBridge.currentHardwareInfo;
      if (info.sampleRate < RecordingSessionConstants.minSampleRate ||
          info.outputBufferFrames < RecordingSessionConstants.minBufferFrames ||
          info.inputBufferFrames < RecordingSessionConstants.minBufferFrames) {
        return const Err(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Hardware info contains invalid sampleRate or buffer frame sizes.',
          ),
        );
      }
      return Ok(info);
    } on StateError catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.audioDeviceInitFailed,
          'Audio engine hardware info is unavailable before initialization.',
          cause: error,
        ),
      );
    }
  }

  Future<T> _runSerializedWrite<T>(Future<T> Function() action) {
    final serializer = _serializedProjectWrite;
    if (serializer != null) {
      return serializer(action);
    }
    return action();
  }

  Result<TempoTimelineCalculator> _buildTimelineResult(
    ProjectWorkspaceAggregate aggregate,
  ) {
    try {
      return Ok(
        TempoTimelineCalculator(
          tempoEvents: aggregate.tempoEvents,
          timeSignatureEvents: aggregate.timeSignatureEvents,
          pickupTicks: aggregate.project.pickupTicks,
        ),
      );
    } on ArgumentError catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid project tempo or time signature timeline: ${error.message}',
          cause: error,
        ),
      );
    }
  }

  Result<Tick> _safeComputeAlignedStartTick({
    required TempoTimelineCalculator calculator,
    required SampleFrame capturedPlayheadFrame,
    required int outputBufferFrames,
    required int inputBufferFrames,
    required int calibrationOffsetFrames,
    required int sampleRate,
  }) {
    try {
      return Ok(
        calculator.computeLatencyCompensatedStartTick(
          capturedPlayheadFrame: capturedPlayheadFrame,
          outputBufferFrames: outputBufferFrames,
          inputBufferFrames: inputBufferFrames,
          calibrationOffsetFrames: calibrationOffsetFrames,
          sampleRate: sampleRate,
        ),
      );
    } on ArgumentError catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Failed to compute latency-compensated take start tick: ${error.message}',
          cause: error,
        ),
      );
    }
  }

  Future<Result<void>> _setArmedPartSuppression(
    PartId? partId, {
    ScoreWorkspaceState? updatedWorkspace,
  }) async {
    final override = _armedPartSuppressionOverride;
    if (override != null) {
      final res = await override(partId);
      if (res.isErr) {
        return res;
      }
      if (updatedWorkspace != null) {
        return _playbackCoordinator.refreshActiveTakeRegionsIfAttached(
          updatedWorkspace.aggregate.project.projectId,
          updatedWorkspace: updatedWorkspace,
        );
      }
      return res;
    }
    return _playbackCoordinator.setArmedRecordingPartSuppression(
      partId,
      updatedWorkspace: updatedWorkspace,
    );
  }

  SoundFontHandle? _resolvePercussionSoundFont() {
    final provider = _percussionSoundFontProvider;
    if (provider != null) {
      return provider();
    }
    return _playbackCoordinator.preferredPercussionSoundFontHandle;
  }

  Future<Result<void>> _runCountInMetronome({
    required ProjectWorkspaceAggregate aggregate,
    required Tick countInStartTick,
    required int sampleRate,
    required int countInMeasures,
  }) async {
    final ts = _activeTimeSignatureAt(
      aggregate.timeSignatureEvents,
      countInStartTick,
    );
    final usPerQuarter = _activeTempoAt(aggregate.tempoEvents, countInStartTick);
    final beatTicks = MuseConstants.wholeNoteTicks ~/ ts.denominator;
    final beatsPerBar = ts.numerator;
    final barTicks = beatTicks * beatsPerBar;
    final totalCountInTicks = barTicks * countInMeasures;
    final totalBeats = beatsPerBar * countInMeasures;
    final clickDurationTicks = math.max(
      RecordingSessionConstants.minPositiveDurationTicks,
      beatTicks ~/ RecordingSessionConstants.countInClickDurationDenominator,
    );

    final calculatorResult = _buildTimelineResult(aggregate);
    if (calculatorResult case Err<TempoTimelineCalculator>(:final error)) {
      return Err(error);
    }
    final calculator = (calculatorResult as Ok<TempoTimelineCalculator>).value;

    final percussionHandle = _resolvePercussionSoundFont();
    var patchedPercussionChannel = false;
    var preRollTransportPlaying = false;
    try {
      if (percussionHandle != null) {
        final patchResult = _synthEventBridge.assignChannelPatch(
          midiChannel: MuseConstants.countInMidiChannel,
          sfHandle: percussionHandle,
          bankNum: MuseConstants.countInBankNum,
          programNum: MuseConstants.countInProgramNum,
        );
        if (patchResult case Err<void>(:final error)) {
          return Err(error);
        }
        patchedPercussionChannel = true;
      }

      if (countInStartTick.value >= totalCountInTicks) {
        final preRollStartTick = Tick(
          countInStartTick.value - totalCountInTicks,
        );
        final preRollStartFrame = calculator.tickToSampleFrame(
          preRollStartTick,
          sampleRate: sampleRate,
        );
        final preRollEndFrame = calculator.tickToSampleFrame(
          countInStartTick,
          sampleRate: sampleRate,
        );

        final seekResult = _transportBridge.seekToSample(preRollStartFrame);
        if (seekResult case Err<EpochId>(:final error)) {
          return Err(error);
        }
        final epoch = (seekResult as Ok<EpochId>).value;

        final events = <ScheduledMidiEvent>[];
        for (var beat = 0; beat < totalBeats; beat++) {
          final beatTick = Tick(preRollStartTick.value + (beat * beatTicks));
          final onFrame = calculator.tickToSampleFrame(
            beatTick,
            sampleRate: sampleRate,
          );
          final offFrame = calculator.tickToSampleFrame(
            Tick(beatTick.value + clickDurationTicks),
            sampleRate: sampleRate,
          );
          final isAccent =
              (beat % beatsPerBar) == RecordingSessionConstants.firstBeatIndex;
          final key = isAccent
              ? MuseConstants.countInAccentKey
              : MuseConstants.countInBeatKey;
          final velocity = isAccent
              ? MuseConstants.countInAccentVelocity
              : MuseConstants.countInBeatVelocity;

          events.add(
            ScheduledMidiEvent(
              epoch: epoch,
              targetSampleFrame: onFrame,
              type: MuseConstants.midiEventNoteOn,
              channel: MuseConstants.countInMidiChannel,
              data1: key,
              data2: velocity,
            ),
          );
          events.add(
            ScheduledMidiEvent(
              epoch: epoch,
              targetSampleFrame: offFrame,
              type: MuseConstants.midiEventNoteOff,
              channel: MuseConstants.countInMidiChannel,
              data1: key,
              data2: RecordingSessionConstants.noteOffVelocity,
            ),
          );
        }

        final schedResult = _synthEventBridge.scheduleEvents(events);
        if (schedResult case Err<int>(:final error)) {
          return Err(error);
        }

        final playResult = _transportBridge.play();
        if (playResult case Err<void>(:final error)) {
          return Err(error);
        }
        preRollTransportPlaying = true;

        final preRollFrames = math.max(
          0,
          preRollEndFrame.value - preRollStartFrame.value,
        );
        final waitUs =
            (BigInt.from(preRollFrames) *
                    BigInt.from(
                      RecordingSessionConstants.microsecondsPerSecond,
                    ) ~/
                    BigInt.from(sampleRate))
                .toInt();
        if (waitUs > 0) {
          await _countInDelay(Duration(microseconds: waitUs));
        }

        final pauseResult = _transportBridge.pause();
        preRollTransportPlaying = false;
        _synthEventBridge.flushAndAdvanceEpoch();
        if (pauseResult case Err<void>(:final error)) {
          return Err(error);
        }
        return const Ok(null);
      }

      // Punch-in near bar start (< totalCountInTicks): emit immediate-frame clicks.
      final beatUs =
          (BigInt.from(beatTicks) *
                  BigInt.from(usPerQuarter) ~/
                  BigInt.from(MuseConstants.ppqn))
              .toInt();
      final clickUs = math.max(
        RecordingSessionConstants.minClickDurationMicroseconds,
        (BigInt.from(clickDurationTicks) *
                BigInt.from(usPerQuarter) ~/
                BigInt.from(MuseConstants.ppqn))
            .toInt(),
      );

      for (var beat = 0; beat < totalBeats; beat++) {
        final isAccent =
            (beat % beatsPerBar) == RecordingSessionConstants.firstBeatIndex;
        final key = isAccent
            ? MuseConstants.countInAccentKey
            : MuseConstants.countInBeatKey;
        final velocity = isAccent
            ? MuseConstants.countInAccentVelocity
            : MuseConstants.countInBeatVelocity;

        final onResult = _synthEventBridge.scheduleEvents([
          ScheduledMidiEvent(
            epoch: _synthEventBridge.currentEpoch,
            targetSampleFrame: const SampleFrame(
              MuseConstants.immediateDispatchFrame,
            ),
            type: MuseConstants.midiEventNoteOn,
            channel: MuseConstants.countInMidiChannel,
            data1: key,
            data2: velocity,
          ),
        ]);
        if (onResult case Err<int>(:final error)) {
          return Err(error);
        }

        await _countInDelay(Duration(microseconds: clickUs));

        final offResult = _synthEventBridge.scheduleEvents([
          ScheduledMidiEvent(
            epoch: _synthEventBridge.currentEpoch,
            targetSampleFrame: const SampleFrame(
              MuseConstants.immediateDispatchFrame,
            ),
            type: MuseConstants.midiEventNoteOff,
            channel: MuseConstants.countInMidiChannel,
            data1: key,
            data2: RecordingSessionConstants.noteOffVelocity,
          ),
        ]);
        if (offResult case Err<int>(:final error)) {
          return Err(error);
        }

        final restUs = math.max(0, beatUs - clickUs);
        if (restUs > 0) {
          await _countInDelay(Duration(microseconds: restUs));
        }
      }

      return const Ok(null);
    } finally {
      if (preRollTransportPlaying) {
        _transportBridge.pause();
        _synthEventBridge.flushAndAdvanceEpoch();
      }
      if (patchedPercussionChannel) {
        _playbackCoordinator.restoreChannelPatches();
      }
    }
  }

  static ({int numerator, int denominator}) _activeTimeSignatureAt(
    List<TimeSignatureEventEntity> events,
    Tick targetTick,
  ) {
    TimeSignatureEventEntity? best;
    for (final evt in events) {
      if (evt.tick.value <= targetTick.value &&
          (best == null || evt.tick.value >= best.tick.value)) {
        best = evt;
      }
    }
    if (best == null) {
      return (
        numerator: RecordingSessionConstants.defaultTimeSigNumerator,
        denominator: RecordingSessionConstants.defaultTimeSigDenominator,
      );
    }
    return (numerator: best.numerator, denominator: best.denominator);
  }

  static int _activeTempoAt(List<TempoEventEntity> events, Tick targetTick) {
    TempoEventEntity? best;
    for (final evt in events) {
      if (evt.tick.value <= targetTick.value &&
          (best == null || evt.tick.value >= best.tick.value)) {
        best = evt;
      }
    }
    return best?.usPerQuarter ??
        RecordingSessionConstants.defaultTempoUsPerQuarter;
  }

  static ScoreWorkspaceState _workspaceWithUpdatedTakes(
    ScoreWorkspaceState base,
    List<AudioTakeEntity> updatedTakes,
  ) {
    final byPartId = <PartId, AudioTakeEntity>{
      for (final take in base.aggregate.audioTakes) take.partId: take,
    };
    for (final take in updatedTakes) {
      byPartId[take.partId] = take;
    }
    return ScoreWorkspaceState(
      aggregate: ProjectWorkspaceAggregate(
        project: base.aggregate.project,
        parts: base.aggregate.parts,
        tempoEvents: base.aggregate.tempoEvents,
        timeSignatureEvents: base.aggregate.timeSignatureEvents,
        keySignatureEvents: base.aggregate.keySignatureEvents,
        clefEvents: base.aggregate.clefEvents,
        notes: base.aggregate.notes,
        spanners: base.aggregate.spanners,
        audioTakes: byPartId.values.toList(growable: false),
      ),
      renderSnapshot: base.renderSnapshot,
    );
  }
}
