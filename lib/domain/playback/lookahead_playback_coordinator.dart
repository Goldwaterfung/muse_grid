/// Pure Dart L4 lookahead playback coordinator contract and implementation
/// bridging score state to the real-time audio engine (`IAudioLifecycleBridge`,
/// `ITransportBridge`, `ISynthEventBridge`, and `ITelemetryBridge`).
library;

import 'dart:async';
import 'dart:math' as math;

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../models/score_models.dart';
import '../notation/dual_model_score_service.dart';
import '../repositories/storage_contracts.dart';
import '../timeline/tempo_timeline_calculator.dart';

/// Signature for injecting a custom periodic timer factory in unit tests.
typedef PeriodicTimerFactory =
    Timer Function(Duration interval, void Function(Timer timer) callback);

/// Loop and attachment state broadcast when attach, detach, or loop bounds change.
typedef PlaybackLoopStateSnapshot = ({
  bool isAttached,
  bool isLoopEnabled,
  ({Tick startTick, Tick endTick})? loopTickRange,
});

/// Emitted when a tempo-map edit re-anchors the audio engine's playhead sample
/// frame so the current musical tick position is preserved.
typedef PlaybackPlayheadReanchorEvent = ({
  Tick tick,
  SampleFrame sampleFrame,
});

/// Centralized constants for [LookaheadPlaybackCoordinator].
abstract final class LookaheadPlaybackConstants {
  static const int millisecondsPerSecond = 1000;
  static const double mutedGainDb = -96.0;
  static const double neutralPan = 0.0;
  static const int noteOffReleaseVelocity = 0;
  static const int minFrame = 0;
  static const int minTick = 0;
  static const int minSampleRate = 1;
  static const int singleLoopStep = 1;
  static const int noteOffSortPriority = 0;
  static const int noteOnSortPriority = 1;
  static const int minAuditionNotesLength = 1;
  static const int loopPassBits = 16;
  static const int loopPassMask = 0xFFFF;
  static const int binaryTreeRootIndex = 1;
  static const int binaryTreeLeftShift = 1;
}

/// Pure Dart contract for project audio session attachment, transport control,
/// rolling `25 ms` / `200 ms` MIDI lookahead scheduling, and live auditioning.
abstract interface class ILookaheadPlaybackCoordinator {
  bool get isAttached;

  bool get isPlaying;

  bool get isLoopEnabled;

  ({Tick startTick, Tick endTick})? get loopTickRange;

  SoundFontHandle? get preferredPercussionSoundFontHandle;

  /// Stream of asynchronous background synchronization failures (SoundFont loading,
  /// WAV take registration, channel patch/mix updates, or timer lookahead refills).
  Stream<MuseError> get asyncErrors;

  /// Broadcasts loop and attachment state whenever project attachment or loop
  /// boundaries change.
  Stream<PlaybackLoopStateSnapshot> get loopStateChanges;

  /// Broadcasts when a timeline tempo mutation re-anchors the playhead frame to
  /// preserve the current musical tick.
  Stream<PlaybackPlayheadReanchorEvent> get playheadReanchored;

  Future<Result<void>> attachProject(ScoreWorkspaceState workspace);

  Future<void> detachProject();

  Future<Result<void>> unloadUnusedSoundFont(SoundFontId sfId);

  Future<Result<void>> setArmedRecordingPartSuppression(
    PartId? partId, {
    ScoreWorkspaceState? updatedWorkspace,
  });

  Future<Result<void>> refreshActiveTakeRegionsIfAttached(
    ProjectId projectId, {
    ScoreWorkspaceState? updatedWorkspace,
  });

  Result<void> restoreChannelPatches();

  Future<Result<void>> play();

  Result<void> pause();

  Result<void> stop();

  Result<void> seekToTick(Tick targetTick);

  Result<void> setLoopTickRange({
    required bool enabled,
    required Tick startTick,
    required Tick endTick,
  });

  Result<void> auditionNote({
    required PartId partId,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  });

  /// Called by `ScoreEditingCommandBus` when notes, tempo, meter, mixer,
  /// or active audio takes change during playback.
  void notifyScoreMutatedInRange({
    required Tick affectedStartTick,
    required Tick affectedEndTick,
  });

  Future<void> dispose();
}

/// Concrete L4 lookahead playback coordinator managing SF2 caching, active WAV
/// take filtering, channel patching/mixing, and bounded `200 ms` MIDI scheduling.
final class LookaheadPlaybackCoordinator
    implements ILookaheadPlaybackCoordinator {
  final IAudioLifecycleBridge _lifecycleBridge;
  final ITransportBridge _transportBridge;
  final ISynthEventBridge _synthEventBridge;
  final ITelemetryBridge _telemetryBridge;
  final IAssetLibraryRepository _assetLibraryRepository;
  final ScoreWorkspaceState? Function()? _workspaceStateProvider;
  final PeriodicTimerFactory _periodicTimerFactory;

  final Map<SoundFontId, SoundFontHandle> _loadedSoundFonts =
      <SoundFontId, SoundFontHandle>{};
  final Set<SoundFontId> _pendingSoundFontLoads = <SoundFontId>{};
  final Set<int> _assignedChannels = <int>{};

  ScoreWorkspaceState? _workspace;
  TempoTimelineCalculator? _timeline;
  bool _isAttached = false;
  bool _isPlaying = false;
  int _playheadAnchorFrame = LookaheadPlaybackConstants.minFrame;
  int _scheduledUpToFrame = LookaheadPlaybackConstants.minFrame;
  bool _loopEnabled = false;
  ({Tick startTick, Tick endTick})? _loopTickRange;
  int _loopStartFrame = LookaheadPlaybackConstants.minFrame;
  int _loopEndFrame = LookaheadPlaybackConstants.minFrame;
  int _loopPassIndex = 0;
  int _lastLoopPlayheadFrame = LookaheadPlaybackConstants.minFrame;
  bool _inLoopPhase = false;
  PartId? _suppressedTakePartId;
  Timer? _refillTimer;
  _CompiledNoteFrameIndex? _compiledNoteIndex;
  final StreamController<MuseError> _asyncErrorController =
      StreamController<MuseError>.broadcast();
  final StreamController<PlaybackLoopStateSnapshot> _loopStateController =
      StreamController<PlaybackLoopStateSnapshot>.broadcast();
  final StreamController<PlaybackPlayheadReanchorEvent>
  _playheadReanchoredController =
      StreamController<PlaybackPlayheadReanchorEvent>.broadcast();

  LookaheadPlaybackCoordinator({
    required this._lifecycleBridge,
    required this._transportBridge,
    required this._synthEventBridge,
    required this._telemetryBridge,
    required this._assetLibraryRepository,
    this._workspaceStateProvider,
    PeriodicTimerFactory? periodicTimerFactory,
  }) : _periodicTimerFactory = periodicTimerFactory ?? Timer.periodic;

  @override
  bool get isAttached => _isAttached;

  @override
  bool get isPlaying => _isPlaying;

  @override
  bool get isLoopEnabled => _loopEnabled;

  @override
  ({Tick startTick, Tick endTick})? get loopTickRange => _loopTickRange;

  @override
  Stream<MuseError> get asyncErrors => _asyncErrorController.stream;

  @override
  Stream<PlaybackLoopStateSnapshot> get loopStateChanges =>
      _loopStateController.stream;

  @override
  Stream<PlaybackPlayheadReanchorEvent> get playheadReanchored =>
      _playheadReanchoredController.stream;

  /// Currently attached workspace state, or `null` when detached.
  ScoreWorkspaceState? get attachedWorkspace => _workspace;

  /// Best available loaded SoundFont handle for count-in percussion on GM Ch 9.
  @override
  SoundFontHandle? get preferredPercussionSoundFontHandle {
    final workspace = _currentWorkspace();
    if (workspace != null) {
      for (final part in workspace.aggregate.parts) {
        if (part.midiChannel == MuseConstants.gmPercussionChannel &&
            part.sfId != null) {
          final handle = _loadedSoundFonts[part.sfId!];
          if (handle != null) {
            return handle;
          }
        }
      }
    }
    return _loadedSoundFonts.values.firstOrNull;
  }

  /// Exposes internal suppression control for `RecordingSessionCoordinator`
  /// so prior WAV takes on an armed recording part stay silent during overdub.
  @override
  Future<Result<void>> setArmedRecordingPartSuppression(
    PartId? partId, {
    ScoreWorkspaceState? updatedWorkspace,
  }) async {
    _suppressedTakePartId = partId;
    if (!_isAttached) {
      return const Ok(null);
    }
    if (updatedWorkspace != null &&
        _workspace != null &&
        updatedWorkspace.aggregate.project.projectId ==
            _workspace!.aggregate.project.projectId) {
      _workspace = updatedWorkspace;
    }
    final workspace = updatedWorkspace ?? _currentWorkspace();
    final timeline = _timeline;
    if (workspace == null || timeline == null) {
      return const Ok(null);
    }
    final srResult = _readHardwareSampleRate();
    if (srResult case Err<int>(:final error)) {
      return Err(error);
    }
    final sampleRate = (srResult as Ok<int>).value;
    return _syncActiveTakes(workspace.aggregate, timeline, sampleRate);
  }

  /// Re-syncs active WAV take regions if [projectId] is currently attached.
  @override
  Future<Result<void>> refreshActiveTakeRegionsIfAttached(
    ProjectId projectId, {
    ScoreWorkspaceState? updatedWorkspace,
  }) async {
    if (!_isAttached) {
      return const Ok(null);
    }
    final liveWorkspace =
        updatedWorkspace ?? _workspaceStateProvider?.call() ?? _workspace;
    if (liveWorkspace == null ||
        liveWorkspace.aggregate.project.projectId != projectId) {
      return const Ok(null);
    }
    _workspace = liveWorkspace;
    final timeline = _timeline;
    if (timeline == null) {
      return const Ok(null);
    }
    final srResult = _readHardwareSampleRate();
    if (srResult case Err<int>(:final error)) {
      return Err(error);
    }
    final sampleRate = (srResult as Ok<int>).value;
    return _syncActiveTakes(liveWorkspace.aggregate, timeline, sampleRate);
  }

  @override
  Result<void> restoreChannelPatches() {
    final attachedError = _requireAttached();
    if (attachedError != null) {
      return Err(attachedError);
    }
    final workspace = _currentWorkspace()!;
    final usesPercussionChannel = workspace.aggregate.parts.any(
      (part) => part.midiChannel == MuseConstants.gmPercussionChannel,
    );
    if (!usesPercussionChannel) {
      final silenceRes = _synthEventBridge.silenceChannel(
        MuseConstants.gmPercussionChannel,
      );
      if (silenceRes case Err<void>(:final error)) {
        return Err(error);
      }
    }
    return _applyChannelPatchesAndMixes(workspace.aggregate);
  }

  @override
  Future<void> dispose() async {
    await detachProject();
    if (!_asyncErrorController.isClosed) {
      await _asyncErrorController.close();
    }
    if (!_loopStateController.isClosed) {
      await _loopStateController.close();
    }
    if (!_playheadReanchoredController.isClosed) {
      await _playheadReanchoredController.close();
    }
  }

  @override
  Future<Result<void>> attachProject(ScoreWorkspaceState workspace) async {
    if (_isAttached) {
      await detachProject();
    }

    final srResult = _readHardwareSampleRate();
    if (srResult case Err<int>(:final error)) {
      return Err(error);
    }
    final sampleRate = (srResult as Ok<int>).value;

    final agg = workspace.aggregate;
    final noteCountByPart = <PartId, int>{};
    for (final note in agg.notes) {
      noteCountByPart[note.partId] = (noteCountByPart[note.partId] ?? 0) + 1;
    }

    final neededSfIds = <SoundFontId>{};
    for (final part in agg.parts) {
      final hasNotes =
          (noteCountByPart[part.partId] ?? 0) >=
          LookaheadPlaybackConstants.minAuditionNotesLength;
      if (!part.isMuted && hasNotes && part.sfId == null) {
        return Err(
          MuseError(
            MuseErrorCode.missingSoundFontForPart,
            'Non-muted part "${part.name}" (${part.partId.value}) has notes '
            'without an assigned SoundFont.',
          ),
        );
      }
      if (part.sfId != null) {
        neededSfIds.add(part.sfId!);
      }
    }

    final newlyLoadedIds = <SoundFontId>[];
    if (neededSfIds.isNotEmpty) {
      final sfCatalogResult = await _assetLibraryRepository
          .listActiveSoundFonts();
      if (sfCatalogResult case Err<List<SoundFontCatalogEntry>>(:final error)) {
        return Err(error);
      }
      final catalogEntries =
          (sfCatalogResult as Ok<List<SoundFontCatalogEntry>>).value;
      final shaBySfId = <SoundFontId, Sha256Digest>{
        for (final entry in catalogEntries) entry.sfId: entry.blobSha256,
      };

      for (final sfId in neededSfIds) {
        if (_loadedSoundFonts.containsKey(sfId)) {
          continue;
        }
        final sha256 = shaBySfId[sfId];
        if (sha256 == null) {
          await _unloadSpecificSoundFonts(newlyLoadedIds);
          return Err(
            MuseError(
              MuseErrorCode.entityNotFound,
              'Referenced SoundFont "${sfId.value}" does not exist in asset catalog.',
            ),
          );
        }
        final loadResult = await _lifecycleBridge.loadSoundFontFromCas(
          sha256: sha256,
        );
        if (loadResult case Err<LoadedSoundFontDescriptor>(:final error)) {
          await _unloadSpecificSoundFonts(newlyLoadedIds);
          return Err(error);
        }
        final descriptor = (loadResult as Ok<LoadedSoundFontDescriptor>).value;
        _loadedSoundFonts[sfId] = descriptor.handle;
        newlyLoadedIds.add(sfId);
      }
    }

    final timeline = _buildTimeline(agg);
    final channelSyncResult = _applyChannelPatchesAndMixes(agg);
    if (channelSyncResult case Err<void>(:final error)) {
      await _unloadSpecificSoundFonts(newlyLoadedIds);
      return Err(error);
    }

    final takesSyncResult = await _syncActiveTakes(agg, timeline, sampleRate);
    if (takesSyncResult case Err<void>(:final error)) {
      await _unloadSpecificSoundFonts(newlyLoadedIds);
      return Err(error);
    }

    _workspace = workspace;
    _timeline = timeline;
    _isAttached = true;
    _isPlaying = false;
    _playheadAnchorFrame = LookaheadPlaybackConstants.minFrame;
    _scheduledUpToFrame = LookaheadPlaybackConstants.minFrame;
    _loopEnabled = false;
    _loopTickRange = null;
    _loopStartFrame = LookaheadPlaybackConstants.minFrame;
    _loopEndFrame = LookaheadPlaybackConstants.minFrame;
    _loopPassIndex = 0;
    _lastLoopPlayheadFrame = LookaheadPlaybackConstants.minFrame;
    _inLoopPhase = false;
    _compiledNoteIndex = null;
    _emitLoopStateChange();
    return const Ok(null);
  }

  @override
  Future<void> detachProject() async {
    _cancelRefillTimer();
    _isPlaying = false;
    if (_isAttached) {
      _transportBridge.stop();
      _transportBridge.setLoopRegion(
        enabled: false,
        startFrame: const SampleFrame(LookaheadPlaybackConstants.minFrame),
        endFrame: const SampleFrame(LookaheadPlaybackConstants.minFrame),
      );
      _silenceAllChannelsBestEffort();
      await _transportBridge.syncActiveTakeRegions(
        const <ActiveTakePlaybackRegion>[],
      );
    }
    await _unloadSpecificSoundFonts(_loadedSoundFonts.keys.toList());
    _loadedSoundFonts.clear();
    _pendingSoundFontLoads.clear();
    _assignedChannels.clear();
    _workspace = null;
    _timeline = null;
    _isAttached = false;
    _playheadAnchorFrame = LookaheadPlaybackConstants.minFrame;
    _scheduledUpToFrame = LookaheadPlaybackConstants.minFrame;
    _loopEnabled = false;
    _loopTickRange = null;
    _loopStartFrame = LookaheadPlaybackConstants.minFrame;
    _loopEndFrame = LookaheadPlaybackConstants.minFrame;
    _loopPassIndex = 0;
    _lastLoopPlayheadFrame = LookaheadPlaybackConstants.minFrame;
    _inLoopPhase = false;
    _suppressedTakePartId = null;
    _compiledNoteIndex = null;
    _emitLoopStateChange();
  }

  @override
  Future<Result<void>> unloadUnusedSoundFont(SoundFontId sfId) async {
    final handle = _loadedSoundFonts[sfId];
    if (handle == null) {
      return const Ok(null);
    }
    final workspace = _currentWorkspace();
    if (workspace != null &&
        workspace.aggregate.parts.any((part) => part.sfId == sfId)) {
      // SoundFont is still referenced by the attached workspace; keep loaded.
      return const Ok(null);
    }
    final unloadResult = await _lifecycleBridge.unloadSoundFont(handle);
    if (unloadResult case Err<void>(:final error)) {
      return Err(error);
    }
    _loadedSoundFonts.remove(sfId);
    return const Ok(null);
  }

  @override
  Future<Result<void>> play() async {
    final attachedError = _requireAttached();
    if (attachedError != null) {
      return Err(attachedError);
    }
    final srResult = _readHardwareSampleRate();
    if (srResult case Err<int>(:final error)) {
      return Err(error);
    }
    final sampleRate = (srResult as Ok<int>).value;

    final playheadFrame = _currentPlayheadFrame();
    _playheadAnchorFrame = playheadFrame;
    if (!_isPlaying) {
      _scheduledUpToFrame = playheadFrame;
      _resetLoopPhase(playheadFrame);
    }

    final refillResult = _refillLookaheadWindow(
      sampleRate: sampleRate,
      overridePlayheadFrame: playheadFrame,
    );
    if (refillResult case Err<void>(:final error)) {
      return Err(error);
    }

    final playResult = _transportBridge.play();
    if (playResult case Err<void>(:final error)) {
      return Err(error);
    }

    _isPlaying = true;
    _startRefillTimer();
    return const Ok(null);
  }

  @override
  Result<void> pause() {
    final attachedError = _requireAttached();
    if (attachedError != null) {
      return Err(attachedError);
    }
    _cancelRefillTimer();
    _isPlaying = false;
    _playheadAnchorFrame = _currentPlayheadFrame();
    _scheduledUpToFrame = _playheadAnchorFrame;
    _resetLoopPhase(_playheadAnchorFrame);
    final pauseResult = _transportBridge.pause();
    if (pauseResult case Err<void>(:final error)) {
      return Err(error);
    }
    _silenceAllChannelsBestEffort();
    final flushResult = _synthEventBridge.flushAndAdvanceEpoch();
    if (flushResult case Err<EpochId>(:final error)) {
      return Err(error);
    }
    return const Ok(null);
  }

  @override
  Result<void> stop() {
    final attachedError = _requireAttached();
    if (attachedError != null) {
      return Err(attachedError);
    }
    _cancelRefillTimer();
    _isPlaying = false;
    _playheadAnchorFrame = LookaheadPlaybackConstants.minFrame;
    _scheduledUpToFrame = LookaheadPlaybackConstants.minFrame;
    _resetLoopPhase(LookaheadPlaybackConstants.minFrame);

    final stopResult = _transportBridge.stop();
    if (stopResult case Err<void>(:final error)) {
      return Err(error);
    }
    _silenceAllChannelsBestEffort();
    final flushResult = _synthEventBridge.flushAndAdvanceEpoch();
    if (flushResult case Err<EpochId>(:final error)) {
      return Err(error);
    }
    return const Ok(null);
  }

  @override
  Result<void> seekToTick(Tick targetTick) {
    final attachedError = _requireAttached();
    if (attachedError != null) {
      return Err(attachedError);
    }
    if (targetTick.value < LookaheadPlaybackConstants.minTick) {
      return Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Seek targetTick (${targetTick.value}) must be non-negative.',
        ),
      );
    }
    final srResult = _readHardwareSampleRate();
    if (srResult case Err<int>(:final error)) {
      return Err(error);
    }
    final sampleRate = (srResult as Ok<int>).value;

    final targetFrame = _timeline!.tickToSampleFrame(
      targetTick,
      sampleRate: sampleRate,
    );
    final seekResult = _transportBridge.seekToSample(targetFrame);
    if (seekResult case Err<EpochId>(:final error)) {
      return Err(error);
    }

    _playheadAnchorFrame = targetFrame.value;
    _scheduledUpToFrame = targetFrame.value;
    _resetLoopPhase(targetFrame.value);

    if (_isPlaying) {
      final refillResult = _refillLookaheadWindow(
        sampleRate: sampleRate,
        overridePlayheadFrame: targetFrame.value,
      );
      if (refillResult case Err<void>(:final error)) {
        return Err(error);
      }
    }
    return const Ok(null);
  }

  @override
  Result<void> setLoopTickRange({
    required bool enabled,
    required Tick startTick,
    required Tick endTick,
  }) {
    final attachedError = _requireAttached();
    if (attachedError != null) {
      return Err(attachedError);
    }
    if (startTick.value < LookaheadPlaybackConstants.minTick ||
        endTick.value < LookaheadPlaybackConstants.minTick ||
        (enabled && endTick.value <= startTick.value)) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Loop region requires non-negative ticks with endTick > startTick when enabled.',
        ),
      );
    }
    final srResult = _readHardwareSampleRate();
    if (srResult case Err<int>(:final error)) {
      return Err(error);
    }
    final sampleRate = (srResult as Ok<int>).value;

    final startFrame = _timeline!.tickToSampleFrame(
      startTick,
      sampleRate: sampleRate,
    );
    final endFrame = _timeline!.tickToSampleFrame(
      endTick,
      sampleRate: sampleRate,
    );

    final loopResult = _transportBridge.setLoopRegion(
      enabled: enabled,
      startFrame: startFrame,
      endFrame: endFrame,
    );
    if (loopResult case Err<void>(:final error)) {
      return Err(error);
    }

    _loopEnabled = enabled;
    _loopTickRange = enabled ? (startTick: startTick, endTick: endTick) : null;
    _loopStartFrame = startFrame.value;
    _loopEndFrame = endFrame.value;
    final playheadFrame = _currentPlayheadFrame();
    _resetLoopPhase(playheadFrame);
    _emitLoopStateChange();

    if (_isPlaying) {
      final flushResult = _synthEventBridge.flushAndAdvanceEpoch();
      if (flushResult case Err<EpochId>(:final error)) {
        return Err(error);
      }
      _scheduledUpToFrame = playheadFrame;
      _resetLoopPhase(playheadFrame);
      final refillResult = _refillLookaheadWindow(
        sampleRate: sampleRate,
        overridePlayheadFrame: playheadFrame,
      );
      if (refillResult case Err<void>(:final error)) {
        return Err(error);
      }
    } else if (_scheduledUpToFrame > playheadFrame) {
      final flushResult = _synthEventBridge.flushAndAdvanceEpoch();
      if (flushResult case Err<EpochId>(:final error)) {
        return Err(error);
      }
      _scheduledUpToFrame = playheadFrame;
    }
    return const Ok(null);
  }

  @override
  Result<void> auditionNote({
    required PartId partId,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) {
    final attachedError = _requireAttached();
    if (attachedError != null) {
      return Err(attachedError);
    }
    final workspace = _currentWorkspace()!;
    final part = _findPart(workspace.aggregate.parts, partId);
    if (part == null) {
      return Err(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Cannot audition note: part "${partId.value}" was not found.',
        ),
      );
    }
    if (part.midiChannel < MuseConstants.minMidiChannel ||
        part.midiChannel > MuseConstants.maxMidiChannel ||
        pitchMidi < MuseConstants.minMidiPitch ||
        pitchMidi > MuseConstants.maxMidiPitch) {
      return const Err(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'Audition pitchMidi must be in 0..127 and channel in 0..15.',
        ),
      );
    }
    final minVel = isNoteOn
        ? MuseConstants.minMidiVelocity
        : LookaheadPlaybackConstants.noteOffReleaseVelocity;
    if (velocity < minVel || velocity > MuseConstants.maxMidiVelocity) {
      return Err(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'Audition velocity ($velocity) must be within $minVel..${MuseConstants.maxMidiVelocity}.',
        ),
      );
    }
    if (part.sfId == null) {
      return Err(
        MuseError(
          MuseErrorCode.missingSoundFontForPart,
          'Cannot audition note on part "${part.name}": no SoundFont assigned.',
        ),
      );
    }
    final sfHandle = _loadedSoundFonts[part.sfId!];
    if (sfHandle == null) {
      return Err(
        MuseError(
          MuseErrorCode.soundFontLoadFailed,
          'SoundFont "${part.sfId!.value}" is not loaded for part "${part.name}".',
        ),
      );
    }

    final patchResult = _synthEventBridge.assignChannelPatch(
      midiChannel: part.midiChannel,
      sfHandle: sfHandle,
      bankNum: part.bankNum,
      programNum: part.programNum,
    );
    if (patchResult case Err<void>(:final error)) {
      return Err(error);
    }

    return _synthEventBridge.triggerLiveAuditionNote(
      midiChannel: part.midiChannel,
      pitchMidi: pitchMidi,
      velocity: velocity,
      isNoteOn: isNoteOn,
    );
  }

  @override
  void notifyScoreMutatedInRange({
    required Tick affectedStartTick,
    required Tick affectedEndTick,
  }) {
    if (!_isAttached) {
      return;
    }
    final latestWorkspace = _workspaceStateProvider?.call();
    if (latestWorkspace != null) {
      _workspace = latestWorkspace;
    }
    final workspace = _workspace;
    if (workspace == null) {
      return;
    }
    _compiledNoteIndex = null;
    final agg = workspace.aggregate;
    final previousTimeline = _timeline;
    final TempoTimelineCalculator timeline;
    try {
      timeline = _buildTimeline(agg);
    } on ArgumentError catch (error) {
      _emitAsyncError(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid score timeline after mutation: ${error.message}',
          cause: error,
        ),
      );
      return;
    }
    _timeline = timeline;

    final srResult = _readHardwareSampleRate();
    if (srResult case Err<int>(:final error)) {
      _emitAsyncError(error);
      return;
    }
    final sampleRate = (srResult as Ok<int>).value;

    _scheduleMissingPartSoundFontsAsync(agg);
    final patchSyncResult = _applyChannelPatchesAndMixes(agg);
    if (patchSyncResult case Err<void>(:final error)) {
      _emitAsyncError(error);
    }
    unawaited(_syncActiveTakesWithErrorReporting(agg, timeline, sampleRate));

    if (previousTimeline != null &&
        !previousTimeline.hasEquivalentTempoMap(timeline)) {
      _reconcileTimelineAndLoopOnTempoChange(
        previousTimeline: previousTimeline,
        nextTimeline: timeline,
        affectedStartTick: affectedStartTick,
        sampleRate: sampleRate,
      );
      return;
    }

    final playheadFrame = _currentPlayheadFrame();
    final lookaheadFrames = _lookaheadFramesForSampleRate(sampleRate);
    final mutStartFrame = timeline
        .tickToSampleFrame(
          Tick(math.max(LookaheadPlaybackConstants.minTick, affectedStartTick.value)),
          sampleRate: sampleRate,
        )
        .value;
    final mutEndFrame = timeline
        .tickToSampleFrame(
          Tick(
            math.max(
              affectedStartTick.value,
              math.max(LookaheadPlaybackConstants.minTick, affectedEndTick.value),
            ),
          ),
          sampleRate: sampleRate,
        )
        .value;

    final overlapsQueuedWindow = _doesMutationIntersectLookahead(
      mutStartFrame: mutStartFrame,
      mutEndFrame: mutEndFrame,
      playheadFrame: playheadFrame,
      horizonEndFrame: math.max(
        _scheduledUpToFrame,
        playheadFrame + lookaheadFrames,
      ),
    );

    if (!overlapsQueuedWindow) {
      return;
    }

    if (_isPlaying) {
      final flushResult = _synthEventBridge.flushAndAdvanceEpoch();
      if (flushResult case Err<EpochId>(:final error)) {
        _emitAsyncError(error);
        return;
      }
      _scheduledUpToFrame = playheadFrame;
      _resetLoopPhase(playheadFrame);
      final refillResult = _refillLookaheadWindow(
        sampleRate: sampleRate,
        overridePlayheadFrame: playheadFrame,
      );
      if (refillResult case Err<void>(:final error)) {
        _emitAsyncError(error);
      }
    } else if (_scheduledUpToFrame > playheadFrame) {
      final flushResult = _synthEventBridge.flushAndAdvanceEpoch();
      switch (flushResult) {
        case Ok<EpochId>():
          _scheduledUpToFrame = playheadFrame;
          _resetLoopPhase(playheadFrame);
        case Err<EpochId>(:final error):
          _emitAsyncError(error);
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Internal Scheduling, Loop Wrapping & Audio Engine Synchronization
  // ---------------------------------------------------------------------------

  ScoreWorkspaceState? _currentWorkspace() {
    final provided = _workspaceStateProvider?.call();
    if (provided != null) {
      _workspace = provided;
    }
    return _workspace;
  }

  MuseError? _requireAttached() {
    if (!_isAttached || _workspace == null || _timeline == null) {
      return const MuseError(
        MuseErrorCode.audioDeviceInitFailed,
        'Playback operation requires an attached project.',
      );
    }
    return null;
  }

  Result<int> _readHardwareSampleRate() {
    try {
      final sampleRate = _lifecycleBridge.currentHardwareInfo.sampleRate;
      if (sampleRate < LookaheadPlaybackConstants.minSampleRate) {
        return Err(
          MuseError(
            MuseErrorCode.audioDeviceInitFailed,
            'Hardware sampleRate ($sampleRate) must be positive.',
          ),
        );
      }
      return Ok(sampleRate);
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

  int _lookaheadFramesForSampleRate(int sampleRate) {
    return math.max(
      1,
      (MuseConstants.lookaheadWindowMs * sampleRate) ~/
          LookaheadPlaybackConstants.millisecondsPerSecond,
    );
  }

  int _currentPlayheadFrame() {
    final snapshot = _telemetryBridge.latestSnapshot;
    final currentEpoch = _synthEventBridge.currentEpoch;
    if (snapshot != null && snapshot.activeEpoch == currentEpoch) {
      return math.max(
        LookaheadPlaybackConstants.minFrame,
        snapshot.playheadSampleFrame.value,
      );
    }
    return _playheadAnchorFrame;
  }

  TempoTimelineCalculator _buildTimeline(ProjectWorkspaceAggregate agg) {
    return TempoTimelineCalculator(
      tempoEvents: agg.tempoEvents,
      timeSignatureEvents: agg.timeSignatureEvents,
      pickupTicks: agg.project.pickupTicks,
    );
  }

  void _scheduleMissingPartSoundFontsAsync(ProjectWorkspaceAggregate agg) {
    final missingIds = <SoundFontId>{};
    for (final part in agg.parts) {
      final sfId = part.sfId;
      if (sfId != null &&
          !_loadedSoundFonts.containsKey(sfId) &&
          !_pendingSoundFontLoads.contains(sfId)) {
        missingIds.add(sfId);
      }
    }
    if (missingIds.isEmpty) {
      return;
    }
    _pendingSoundFontLoads.addAll(missingIds);
    unawaited(_loadAndBindMissingSoundFonts(missingIds));
  }

  void _emitAsyncError(MuseError error) {
    if (!_asyncErrorController.isClosed) {
      _asyncErrorController.add(error);
    }
  }

  void _emitLoopStateChange() {
    if (!_loopStateController.isClosed) {
      _loopStateController.add((
        isAttached: _isAttached,
        isLoopEnabled: _loopEnabled,
        loopTickRange: _loopTickRange,
      ));
    }
  }

  /// Re-anchors the engine playhead and loop sample-frame bounds whenever the
  /// score's tempo map changes, returning `true` if lookahead was flushed/refilled.
  bool _reconcileTimelineAndLoopOnTempoChange({
    required TempoTimelineCalculator previousTimeline,
    required TempoTimelineCalculator nextTimeline,
    required Tick affectedStartTick,
    required int sampleRate,
  }) {
    final oldPlayheadFrame = _currentPlayheadFrame();
    final lookaheadFrames = _lookaheadFramesForSampleRate(sampleRate);
    final oldHorizonEndFrame = math.max(
      _scheduledUpToFrame,
      oldPlayheadFrame + lookaheadFrames,
    );

    final preservedTick = previousTimeline.sampleFrameToTick(
      SampleFrame(oldPlayheadFrame),
      sampleRate: sampleRate,
    );
    final nextPlayheadFrame = nextTimeline
        .tickToSampleFrame(preservedTick, sampleRate: sampleRate)
        .value;

    var loopBoundsChanged = false;
    final activeLoop = _loopTickRange;
    if (_loopEnabled && activeLoop != null) {
      final nextStartFrame = nextTimeline.tickToSampleFrame(
        activeLoop.startTick,
        sampleRate: sampleRate,
      );
      final nextEndFrame = nextTimeline.tickToSampleFrame(
        activeLoop.endTick,
        sampleRate: sampleRate,
      );
      if (nextStartFrame.value != _loopStartFrame ||
          nextEndFrame.value != _loopEndFrame) {
        final loopRes = _transportBridge.setLoopRegion(
          enabled: true,
          startFrame: nextStartFrame,
          endFrame: nextEndFrame,
        );
        if (loopRes case Err<void>(:final error)) {
          _emitAsyncError(error);
        } else {
          _loopStartFrame = nextStartFrame.value;
          _loopEndFrame = nextEndFrame.value;
          loopBoundsChanged = true;
        }
      }
    }

    final clampedAffectedTick = Tick(
      math.max(LookaheadPlaybackConstants.minTick, affectedStartTick.value),
    );
    final oldMutStartFrame = previousTimeline
        .tickToSampleFrame(clampedAffectedTick, sampleRate: sampleRate)
        .value;
    final nextMutStartFrame = nextTimeline
        .tickToSampleFrame(clampedAffectedTick, sampleRate: sampleRate)
        .value;
    final intersectsLoop =
        _loopEnabled &&
        activeLoop != null &&
        clampedAffectedTick.value < activeLoop.endTick.value;
    final intersectsLookahead =
        oldMutStartFrame < oldHorizonEndFrame ||
        nextMutStartFrame < (nextPlayheadFrame + lookaheadFrames);

    final playheadMoved = nextPlayheadFrame != oldPlayheadFrame;
    if (!playheadMoved &&
        !loopBoundsChanged &&
        !intersectsLoop &&
        !intersectsLookahead) {
      return false;
    }

    if (playheadMoved || loopBoundsChanged) {
      final seekRes = _transportBridge.seekToSample(
        SampleFrame(nextPlayheadFrame),
      );
      if (seekRes case Err<EpochId>(:final error)) {
        _emitAsyncError(error);
        return false;
      }
      _playheadAnchorFrame = nextPlayheadFrame;
      _scheduledUpToFrame = nextPlayheadFrame;
      _resetLoopPhase(nextPlayheadFrame);
      if (!_playheadReanchoredController.isClosed) {
        _playheadReanchoredController.add((
          tick: preservedTick,
          sampleFrame: SampleFrame(nextPlayheadFrame),
        ));
      }
    } else if (_isPlaying || _scheduledUpToFrame > nextPlayheadFrame) {
      final flushRes = _synthEventBridge.flushAndAdvanceEpoch();
      if (flushRes case Err<EpochId>(:final error)) {
        _emitAsyncError(error);
        return false;
      }
      _scheduledUpToFrame = nextPlayheadFrame;
      _resetLoopPhase(nextPlayheadFrame);
    }

    if (_isPlaying) {
      final refillRes = _refillLookaheadWindow(
        sampleRate: sampleRate,
        overridePlayheadFrame: nextPlayheadFrame,
      );
      if (refillRes case Err<void>(:final error)) {
        _emitAsyncError(error);
      }
    }
    return true;
  }

  Future<void> _syncActiveTakesWithErrorReporting(
    ProjectWorkspaceAggregate agg,
    TempoTimelineCalculator timeline,
    int sampleRate,
  ) async {
    final res = await _syncActiveTakes(agg, timeline, sampleRate);
    if (res case Err<void>(:final error)) {
      _emitAsyncError(error);
    }
  }

  Future<void> _loadAndBindMissingSoundFonts(Set<SoundFontId> missingIds) async {
    try {
      final catalogResult = await _assetLibraryRepository.listActiveSoundFonts();
      if (catalogResult case Err<List<SoundFontCatalogEntry>>(:final error)) {
        _emitAsyncError(error);
        return;
      }
      final entries = (catalogResult as Ok<List<SoundFontCatalogEntry>>).value;
      final shaById = <SoundFontId, Sha256Digest>{
        for (final entry in entries) entry.sfId: entry.blobSha256,
      };
      for (final sfId in missingIds) {
        if (!_isAttached || _loadedSoundFonts.containsKey(sfId)) {
          continue;
        }
        final sha = shaById[sfId];
        if (sha == null) {
          _emitAsyncError(
            MuseError(
              MuseErrorCode.entityNotFound,
              'Referenced SoundFont "${sfId.value}" was not found in asset catalog.',
            ),
          );
          continue;
        }
        final loadResult = await _lifecycleBridge.loadSoundFontFromCas(
          sha256: sha,
        );
        switch (loadResult) {
          case Ok<LoadedSoundFontDescriptor>(:final value):
            if (_isAttached) {
              _loadedSoundFonts[sfId] = value.handle;
            } else {
              await _lifecycleBridge.unloadSoundFont(value.handle);
            }
          case Err<LoadedSoundFontDescriptor>(:final error):
            _emitAsyncError(error);
        }
      }
      if (_isAttached) {
        final workspace = _currentWorkspace();
        if (workspace != null) {
          final patchRes = _applyChannelPatchesAndMixes(workspace.aggregate);
          if (patchRes case Err<void>(:final error)) {
            _emitAsyncError(error);
          }
        }
      }
    } finally {
      _pendingSoundFontLoads.removeAll(missingIds);
    }
  }

  Future<void> _unloadSpecificSoundFonts(List<SoundFontId> sfIds) async {
    for (final sfId in sfIds) {
      final handle = _loadedSoundFonts.remove(sfId);
      if (handle != null) {
        await _lifecycleBridge.unloadSoundFont(handle);
      }
    }
  }

  void _silenceAllChannelsBestEffort() {
    for (var ch = 0; ch < MuseConstants.midiChannelCount; ch++) {
      _synthEventBridge.silenceChannel(ch);
    }
  }

  bool _hasAnySoloPart(List<ProjectPartEntity> parts) {
    return parts.any((part) => part.isSolo);
  }

  bool _isPartAudible(ProjectPartEntity part, {required bool hasAnySolo}) {
    return !part.isMuted && (!hasAnySolo || part.isSolo);
  }

  Result<void> _applyChannelPatchesAndMixes(ProjectWorkspaceAggregate agg) {
    final hasAnySolo = _hasAnySoloPart(agg.parts);
    final channelAudible = <int, bool>{};
    final channelMixSource = <int, ProjectPartEntity>{};

    for (final part in agg.parts) {
      final audible = _isPartAudible(part, hasAnySolo: hasAnySolo);
      if (part.sfId != null) {
        final handle = _loadedSoundFonts[part.sfId!];
        if (handle != null && (audible || !channelMixSource.containsKey(part.midiChannel))) {
          final patchRes = _synthEventBridge.assignChannelPatch(
            midiChannel: part.midiChannel,
            sfHandle: handle,
            bankNum: part.bankNum,
            programNum: part.programNum,
          );
          if (patchRes case Err<void>(:final error)) {
            return Err(error);
          }
        }
      }
      final prevAudible = channelAudible[part.midiChannel] ?? false;
      channelAudible[part.midiChannel] = prevAudible || audible;
      if (audible || !channelMixSource.containsKey(part.midiChannel)) {
        channelMixSource[part.midiChannel] = part;
      }
    }

    for (final staleChannel in _assignedChannels.difference(
      channelMixSource.keys.toSet(),
    )) {
      _synthEventBridge.silenceChannel(staleChannel);
    }
    _assignedChannels
      ..clear()
      ..addAll(channelMixSource.keys);

    for (final entry in channelMixSource.entries) {
      final ch = entry.key;
      final part = entry.value;
      final isAudible = channelAudible[ch] ?? false;
      final mixRes = _synthEventBridge.setChannelMix(
        midiChannel: ch,
        gainDb: isAudible ? part.gainDb : LookaheadPlaybackConstants.mutedGainDb,
        pan: part.pan,
      );
      if (mixRes case Err<void>(:final error)) {
        return Err(error);
      }
      if (!isAudible) {
        final silenceRes = _synthEventBridge.silenceChannel(ch);
        if (silenceRes case Err<void>(:final error)) {
          return Err(error);
        }
      }
    }
    return const Ok(null);
  }

  Future<Result<void>> _syncActiveTakes(
    ProjectWorkspaceAggregate agg,
    TempoTimelineCalculator timeline,
    int sampleRate,
  ) {
    final hasAnySolo = _hasAnySoloPart(agg.parts);
    final partsById = <PartId, ProjectPartEntity>{
      for (final part in agg.parts) part.partId: part,
    };

    final regions = <ActiveTakePlaybackRegion>[];
    for (final take in agg.audioTakes) {
      if (take.durationFrames <= 0) {
        continue;
      }
      if (take.partId == _suppressedTakePartId) {
        continue;
      }
      final part = partsById[take.partId];
      if (part == null || !_isPartAudible(part, hasAnySolo: hasAnySolo)) {
        continue;
      }
      final startFrame = timeline.tickToSampleFrame(
        take.startTick,
        sampleRate: sampleRate,
      );
      regions.add(
        ActiveTakePlaybackRegion(
          takeId: take.takeId,
          partId: take.partId,
          wavSha256: take.blobSha256,
          startSampleFrame: startFrame,
          durationFrames: take.durationFrames,
          gainDb: part.gainDb,
          pan: part.pan,
        ),
      );
    }

    if (regions.length > MuseConstants.maxActiveTakeRegions) {
      return Future<Result<void>>.value(
        Err(
          MuseError(
            MuseErrorCode.takeLoadFailed,
            'Audible audio take count (${regions.length}) exceeds '
            'MuseConstants.maxActiveTakeRegions (${MuseConstants.maxActiveTakeRegions}).',
          ),
        ),
      );
    }
    return _transportBridge.syncActiveTakeRegions(regions);
  }

  void _startRefillTimer() {
    _cancelRefillTimer();
    _refillTimer = _periodicTimerFactory(
      const Duration(milliseconds: MuseConstants.lookaheadRefillIntervalMs),
      (_) {
        if (!_isPlaying || !_isAttached) {
          return;
        }
        final srResult = _readHardwareSampleRate();
        switch (srResult) {
          case Ok<int>(:final value):
            final refillResult = _refillLookaheadWindow(sampleRate: value);
            if (refillResult case Err<void>(:final error)) {
              _emitAsyncError(error);
            }
          case Err<int>(:final error):
            _emitAsyncError(error);
        }
      },
    );
  }

  void _cancelRefillTimer() {
    _refillTimer?.cancel();
    _refillTimer = null;
  }

  void _resetLoopPhase(int playheadFrame) {
    _loopPassIndex = 0;
    _lastLoopPlayheadFrame = playheadFrame;
    _inLoopPhase =
        _loopEnabled &&
        _loopEndFrame > _loopStartFrame &&
        playheadFrame >= _loopStartFrame &&
        playheadFrame < _loopEndFrame;
  }

  bool _doesMutationIntersectLookahead({
    required int mutStartFrame,
    required int mutEndFrame,
    required int playheadFrame,
    required int horizonEndFrame,
  }) {
    if (_loopEnabled && _loopEndFrame > _loopStartFrame) {
      final loopLen = _loopEndFrame - _loopStartFrame;
      final horizonSpan = math.max(0, horizonEndFrame - playheadFrame);
      if (horizonSpan >= loopLen) {
        return _rangesOverlap(
          mutStartFrame,
          mutEndFrame,
          _loopStartFrame,
          _loopEndFrame,
        );
      }
      if (playheadFrame >= _loopStartFrame && playheadFrame < _loopEndFrame) {
        final directEnd = math.min(_loopEndFrame, horizonEndFrame);
        if (_rangesOverlap(
          mutStartFrame,
          mutEndFrame,
          playheadFrame,
          directEnd,
        )) {
          return true;
        }
        final wrapOverflow = horizonEndFrame - _loopEndFrame;
        if (wrapOverflow > 0) {
          return _rangesOverlap(
            mutStartFrame,
            mutEndFrame,
            _loopStartFrame,
            _loopStartFrame + wrapOverflow,
          );
        }
        return false;
      }
    }
    return _rangesOverlap(
      mutStartFrame,
      mutEndFrame,
      playheadFrame,
      horizonEndFrame,
    );
  }

  static bool _rangesOverlap(int aStart, int aEnd, int bStart, int bEnd) {
    if (aStart == aEnd) {
      return aStart >= bStart && aStart < bEnd;
    }
    return aStart < bEnd && aEnd > bStart;
  }

  Result<void> _refillLookaheadWindow({
    required int sampleRate,
    int? overridePlayheadFrame,
  }) {
    final workspace = _currentWorkspace();
    final timeline = _timeline;
    if (workspace == null || timeline == null) {
      return const Ok(null);
    }

    final snapshot = _telemetryBridge.latestSnapshot;
    final isCapturing = snapshot?.isCapturing ?? false;
    final playheadFrame = overridePlayheadFrame ?? _currentPlayheadFrame();
    _playheadAnchorFrame = playheadFrame;
    final lookaheadFrames = _lookaheadFramesForSampleRate(sampleRate);
    final epoch = _synthEventBridge.currentEpoch;
    final agg = workspace.aggregate;

    final loopActive =
        !isCapturing && _loopEnabled && _loopEndFrame > _loopStartFrame;
    if (loopActive && playheadFrame >= _loopStartFrame) {
      final loopLen = _loopEndFrame - _loopStartFrame;
      final normalizedPlayhead = playheadFrame >= _loopEndFrame
          ? _loopStartFrame + ((playheadFrame - _loopStartFrame) % loopLen)
          : playheadFrame;

      final telemetryPass =
          (snapshot != null && snapshot.activeEpoch == epoch)
          ? snapshot.loopPass
          : null;
      if (telemetryPass != null) {
        if (!_inLoopPhase) {
          _inLoopPhase = true;
          _loopPassIndex = telemetryPass;
        } else {
          final passDelta =
              (telemetryPass -
                      (_loopPassIndex & LookaheadPlaybackConstants.loopPassMask))
                  .toSigned(LookaheadPlaybackConstants.loopPassBits);
          if (passDelta > 0) {
            _loopPassIndex += passDelta;
          }
        }
      } else if (!_inLoopPhase) {
        _inLoopPhase = true;
        _loopPassIndex = 0;
      } else if (normalizedPlayhead < _lastLoopPlayheadFrame) {
        _loopPassIndex += LookaheadPlaybackConstants.singleLoopStep;
      }
      _lastLoopPlayheadFrame = normalizedPlayhead;

      final virtualPlayhead = normalizedPlayhead + (_loopPassIndex * loopLen);
      final virtualStart = math.max(virtualPlayhead, _scheduledUpToFrame);
      final virtualEnd = virtualPlayhead + lookaheadFrames;
      if (virtualStart >= virtualEnd) {
        return const Ok(null);
      }

      final events = <ScheduledMidiEvent>[];
      var cursor = virtualStart;
      while (cursor < virtualEnd) {
        final offsetFromLoopStart = cursor - _loopStartFrame;
        final passOffset = offsetFromLoopStart ~/ loopLen;
        final passStartVirtual = _loopStartFrame + (passOffset * loopLen);
        final passEndVirtual = passStartVirtual + loopLen;
        final segEndVirtual = math.min(virtualEnd, passEndVirtual);

        final sliceStart = cursor - (passOffset * loopLen);
        final sliceEnd = segEndVirtual - (passOffset * loopLen);
        final isLoopTailSlice = sliceEnd == _loopEndFrame;

        events.addAll(
          _compileMidiEventsForSlice(
            agg: agg,
            timeline: timeline,
            epoch: epoch,
            sampleRate: sampleRate,
            sliceStartFrame: sliceStart,
            sliceEndFrame: sliceEnd,
            clipNotesAtLoopEnd: isLoopTailSlice,
            loopPass: passOffset & LookaheadPlaybackConstants.loopPassMask,
          ),
        );
        cursor = segEndVirtual;
      }

      final physicalWatermark = math.min(
        virtualEnd - (_loopPassIndex * loopLen),
        _loopEndFrame,
      );
      final schedRes = _synthEventBridge.scheduleEvents(
        events,
        scheduledUpToFrame: SampleFrame(physicalWatermark),
      );
      if (schedRes case Err<int>(:final error)) {
        return Err(error);
      }
      _scheduledUpToFrame = virtualEnd;
      return const Ok(null);
    }

    _inLoopPhase = false;
    final windowStart = math.max(playheadFrame, _scheduledUpToFrame);
    final rawWindowEnd = playheadFrame + lookaheadFrames;
    final windowEnd = loopActive && playheadFrame < _loopEndFrame
        ? math.min(rawWindowEnd, _loopEndFrame)
        : rawWindowEnd;

    if (windowStart >= windowEnd) {
      return const Ok(null);
    }

    final events = _compileMidiEventsForSlice(
      agg: agg,
      timeline: timeline,
      epoch: epoch,
      sampleRate: sampleRate,
      sliceStartFrame: windowStart,
      sliceEndFrame: windowEnd,
      clipNotesAtLoopEnd: loopActive && windowEnd == _loopEndFrame,
    );
    final schedRes = _synthEventBridge.scheduleEvents(
      events,
      scheduledUpToFrame: SampleFrame(windowEnd),
    );
    if (schedRes case Err<int>(:final error)) {
      return Err(error);
    }
    _scheduledUpToFrame = windowEnd;
    return const Ok(null);
  }

  _CompiledNoteFrameIndex _ensureCompiledNoteIndex(
    ProjectWorkspaceAggregate agg,
    TempoTimelineCalculator timeline,
    int sampleRate,
  ) {
    final cached = _compiledNoteIndex;
    if (cached != null &&
        cached.matches(
          notes: agg.notes,
          tempoEvents: agg.tempoEvents,
          timeSigEvents: agg.timeSignatureEvents,
          pickupTicks: agg.project.pickupTicks,
          timingMode: agg.project.playbackTimingMode,
          sampleRate: sampleRate,
        )) {
      return cached;
    }
    final built = _CompiledNoteFrameIndex.build(
      notes: agg.notes,
      tempoEvents: agg.tempoEvents,
      timeSigEvents: agg.timeSignatureEvents,
      pickupTicks: agg.project.pickupTicks,
      timingMode: agg.project.playbackTimingMode,
      timeline: timeline,
      sampleRate: sampleRate,
    );
    _compiledNoteIndex = built;
    return built;
  }

  List<ScheduledMidiEvent> _compileMidiEventsForSlice({
    required ProjectWorkspaceAggregate agg,
    required TempoTimelineCalculator timeline,
    required EpochId epoch,
    required int sampleRate,
    required int sliceStartFrame,
    required int sliceEndFrame,
    required bool clipNotesAtLoopEnd,
    int loopPass = 0,
  }) {
    final index = _ensureCompiledNoteIndex(agg, timeline, sampleRate);
    if (index.isEmpty) {
      return const <ScheduledMidiEvent>[];
    }

    final hasAnySolo = _hasAnySoloPart(agg.parts);
    final partById = <PartId, ProjectPartEntity>{
      for (final part in agg.parts) part.partId: part,
    };
    final compiled = <ScheduledMidiEvent>[];

    // 1. Query note-on events falling within [sliceStartFrame, sliceEndFrame).
    for (final note in index.queryNoteOns(sliceStartFrame, sliceEndFrame)) {
      final part = partById[note.partId];
      if (part == null || !_isPartAudible(part, hasAnySolo: hasAnySolo)) {
        continue;
      }
      compiled.add(
        ScheduledMidiEvent(
          epoch: epoch,
          targetSampleFrame: SampleFrame(note.noteOnFrame),
          type: MuseConstants.midiEventNoteOn,
          channel: part.midiChannel,
          data1: note.pitchMidi,
          data2: note.velocity,
          loopPass: loopPass,
        ),
      );
    }

    // 2. Query natural note-off events falling within [sliceStartFrame, sliceEndFrame).
    for (final note in index.queryNoteOffs(sliceStartFrame, sliceEndFrame)) {
      final part = partById[note.partId];
      if (part == null || !_isPartAudible(part, hasAnySolo: hasAnySolo)) {
        continue;
      }
      final startsInsideLoop =
          note.noteOnFrame >= _loopStartFrame && note.noteOnFrame < _loopEndFrame;
      if (clipNotesAtLoopEnd &&
          startsInsideLoop &&
          note.rawNoteOffFrame >= _loopEndFrame) {
        continue;
      }
      compiled.add(
        ScheduledMidiEvent(
          epoch: epoch,
          targetSampleFrame: SampleFrame(note.rawNoteOffFrame),
          type: MuseConstants.midiEventNoteOff,
          channel: part.midiChannel,
          data1: note.pitchMidi,
          data2: LookaheadPlaybackConstants.noteOffReleaseVelocity,
          loopPass: loopPass,
        ),
      );
    }

    // 3. Query sustaining notes started inside [loopStartFrame, loopEndFrame)
    //    whose natural release exceeds loopEndFrame and clip them at wrap.
    if (clipNotesAtLoopEnd && _loopEndFrame > _loopStartFrame) {
      final clippedNotes = index.queryNotesStartedInRangeEndingAtOrAfter(
        rangeStartFrame: _loopStartFrame,
        rangeEndFrame: _loopEndFrame,
        minRawOffFrame: _loopEndFrame,
      );
      for (final note in clippedNotes) {
        final part = partById[note.partId];
        if (part == null || !_isPartAudible(part, hasAnySolo: hasAnySolo)) {
          continue;
        }
        final clippedFrame = math.max(note.noteOnFrame, _loopEndFrame - 1);
        if (clippedFrame >= sliceStartFrame && clippedFrame < sliceEndFrame) {
          compiled.add(
            ScheduledMidiEvent(
              epoch: epoch,
              targetSampleFrame: SampleFrame(clippedFrame),
              type: MuseConstants.midiEventNoteOff,
              channel: part.midiChannel,
              data1: note.pitchMidi,
              data2: LookaheadPlaybackConstants.noteOffReleaseVelocity,
              loopPass: loopPass,
            ),
          );
        }
      }
    }

    compiled.sort((a, b) {
      final frameCmp = a.targetSampleFrame.value.compareTo(
        b.targetSampleFrame.value,
      );
      if (frameCmp != 0) {
        return frameCmp;
      }
      final prioA = a.type == MuseConstants.midiEventNoteOff
          ? LookaheadPlaybackConstants.noteOffSortPriority
          : LookaheadPlaybackConstants.noteOnSortPriority;
      final prioB = b.type == MuseConstants.midiEventNoteOff
          ? LookaheadPlaybackConstants.noteOffSortPriority
          : LookaheadPlaybackConstants.noteOnSortPriority;
      final typeCmp = prioA.compareTo(prioB);
      if (typeCmp != 0) {
        return typeCmp;
      }
      final chCmp = a.channel.compareTo(b.channel);
      if (chCmp != 0) {
        return chCmp;
      }
      return a.data1.compareTo(b.data1);
    });

    return compiled;
  }

  static ProjectPartEntity? _findPart(
    List<ProjectPartEntity> parts,
    PartId partId,
  ) {
    for (final part in parts) {
      if (part.partId == partId) {
        return part;
      }
    }
    return null;
  }
}

final class _IndexedMidiNote {
  final PartId partId;
  final int pitchMidi;
  final int velocity;
  final int noteOnFrame;
  final int rawNoteOffFrame;

  const _IndexedMidiNote({
    required this.partId,
    required this.pitchMidi,
    required this.velocity,
    required this.noteOnFrame,
    required this.rawNoteOffFrame,
  });
}

/// Sample-frame sorted index + segment tree for O(log N + K) lookahead queries.
final class _CompiledNoteFrameIndex {
  final List<TimelineNote> _notesRef;
  final List<TempoEventEntity> _tempoRef;
  final List<TimeSignatureEventEntity> _timeSigRef;
  final int _pickupTicks;
  final PlaybackTimingMode _timingMode;
  final int _sampleRate;
  final List<_IndexedMidiNote> _sortedByOn;
  final List<_IndexedMidiNote> _sortedByOff;
  final int _treeLeafBase;
  final List<int> _maxOffTree;

  const _CompiledNoteFrameIndex._(
    this._notesRef,
    this._tempoRef,
    this._timeSigRef,
    this._pickupTicks,
    this._timingMode,
    this._sampleRate,
    this._sortedByOn,
    this._sortedByOff,
    this._treeLeafBase,
    this._maxOffTree,
  );

  bool get isEmpty => _sortedByOn.isEmpty;

  bool matches({
    required List<TimelineNote> notes,
    required List<TempoEventEntity> tempoEvents,
    required List<TimeSignatureEventEntity> timeSigEvents,
    required int pickupTicks,
    required PlaybackTimingMode timingMode,
    required int sampleRate,
  }) {
    return identical(_notesRef, notes) &&
        identical(_tempoRef, tempoEvents) &&
        identical(_timeSigRef, timeSigEvents) &&
        _pickupTicks == pickupTicks &&
        _timingMode == timingMode &&
        _sampleRate == sampleRate;
  }

  factory _CompiledNoteFrameIndex.build({
    required List<TimelineNote> notes,
    required List<TempoEventEntity> tempoEvents,
    required List<TimeSignatureEventEntity> timeSigEvents,
    required int pickupTicks,
    required PlaybackTimingMode timingMode,
    required TempoTimelineCalculator timeline,
    required int sampleRate,
  }) {
    final useQuantized = timingMode == PlaybackTimingMode.quantized;
    final entries = <_IndexedMidiNote>[];
    for (final note in notes) {
      final startTick = useQuantized
          ? note.quantizedStartTick
          : note.rawStartTick;
      final durationTicks = useQuantized
          ? note.quantizedDurationTicks
          : note.rawDurationTicks;
      if (durationTicks <= 0 ||
          startTick.value < LookaheadPlaybackConstants.minTick) {
        continue;
      }
      final noteOnFrame = timeline
          .tickToSampleFrame(startTick, sampleRate: sampleRate)
          .value;
      final rawNoteOffFrame = timeline
          .tickToSampleFrame(
            Tick(startTick.value + durationTicks),
            sampleRate: sampleRate,
          )
          .value;
      entries.add(
        _IndexedMidiNote(
          partId: note.partId,
          pitchMidi: note.pitchMidi,
          velocity: note.velocity,
          noteOnFrame: noteOnFrame,
          rawNoteOffFrame: rawNoteOffFrame,
        ),
      );
    }

    final byOn = List<_IndexedMidiNote>.of(entries)
      ..sort((a, b) => a.noteOnFrame.compareTo(b.noteOnFrame));
    final byOff = List<_IndexedMidiNote>.of(entries)
      ..sort((a, b) => a.rawNoteOffFrame.compareTo(b.rawNoteOffFrame));

    var leafBase = LookaheadPlaybackConstants.binaryTreeRootIndex;
    while (leafBase < byOn.length) {
      leafBase <<= LookaheadPlaybackConstants.binaryTreeLeftShift;
    }
    final maxOffTree = List<int>.filled(
      leafBase << LookaheadPlaybackConstants.binaryTreeLeftShift,
      LookaheadPlaybackConstants.minFrame,
    );
    for (var i = 0; i < byOn.length; i++) {
      maxOffTree[leafBase + i] = byOn[i].rawNoteOffFrame;
    }
    for (var i = leafBase - 1; i >= LookaheadPlaybackConstants.binaryTreeRootIndex; i--) {
      final leftChild = i << LookaheadPlaybackConstants.binaryTreeLeftShift;
      maxOffTree[i] = math.max(maxOffTree[leftChild], maxOffTree[leftChild | 1]);
    }

    return _CompiledNoteFrameIndex._(
      notes,
      tempoEvents,
      timeSigEvents,
      pickupTicks,
      timingMode,
      sampleRate,
      byOn,
      byOff,
      leafBase,
      maxOffTree,
    );
  }

  Iterable<_IndexedMidiNote> queryNoteOns(int startFrame, int endFrame) {
    if (startFrame >= endFrame || _sortedByOn.isEmpty) {
      return const <_IndexedMidiNote>[];
    }
    final lo = _lowerBoundByOn(startFrame);
    final hi = _lowerBoundByOn(endFrame);
    if (lo >= hi) {
      return const <_IndexedMidiNote>[];
    }
    return _sortedByOn.sublist(lo, hi);
  }

  Iterable<_IndexedMidiNote> queryNoteOffs(int startFrame, int endFrame) {
    if (startFrame >= endFrame || _sortedByOff.isEmpty) {
      return const <_IndexedMidiNote>[];
    }
    final lo = _lowerBoundByOff(startFrame);
    final hi = _lowerBoundByOff(endFrame);
    if (lo >= hi) {
      return const <_IndexedMidiNote>[];
    }
    return _sortedByOff.sublist(lo, hi);
  }

  List<_IndexedMidiNote> queryNotesStartedInRangeEndingAtOrAfter({
    required int rangeStartFrame,
    required int rangeEndFrame,
    required int minRawOffFrame,
  }) {
    if (rangeStartFrame >= rangeEndFrame || _sortedByOn.isEmpty) {
      return const <_IndexedMidiNote>[];
    }
    final qLeft = _lowerBoundByOn(rangeStartFrame);
    final qRight = _lowerBoundByOn(rangeEndFrame);
    if (qLeft >= qRight) {
      return const <_IndexedMidiNote>[];
    }
    final out = <_IndexedMidiNote>[];
    _collectMaxOffRecursive(
      node: LookaheadPlaybackConstants.binaryTreeRootIndex,
      nodeLeft: 0,
      nodeRight: _treeLeafBase,
      qLeft: qLeft,
      qRight: qRight,
      minRawOffFrame: minRawOffFrame,
      out: out,
    );
    return out;
  }

  void _collectMaxOffRecursive({
    required int node,
    required int nodeLeft,
    required int nodeRight,
    required int qLeft,
    required int qRight,
    required int minRawOffFrame,
    required List<_IndexedMidiNote> out,
  }) {
    if (nodeRight <= qLeft ||
        nodeLeft >= qRight ||
        _maxOffTree[node] < minRawOffFrame) {
      return;
    }
    if (node >= _treeLeafBase) {
      out.add(_sortedByOn[node - _treeLeafBase]);
      return;
    }
    final mid = (nodeLeft + nodeRight) >> LookaheadPlaybackConstants.binaryTreeLeftShift;
    final leftChild = node << LookaheadPlaybackConstants.binaryTreeLeftShift;
    _collectMaxOffRecursive(
      node: leftChild,
      nodeLeft: nodeLeft,
      nodeRight: mid,
      qLeft: qLeft,
      qRight: qRight,
      minRawOffFrame: minRawOffFrame,
      out: out,
    );
    _collectMaxOffRecursive(
      node: leftChild | 1,
      nodeLeft: mid,
      nodeRight: nodeRight,
      qLeft: qLeft,
      qRight: qRight,
      minRawOffFrame: minRawOffFrame,
      out: out,
    );
  }

  int _lowerBoundByOn(int targetFrame) {
    var lo = 0;
    var hi = _sortedByOn.length;
    while (lo < hi) {
      final mid = (lo + hi) >> LookaheadPlaybackConstants.binaryTreeLeftShift;
      if (_sortedByOn[mid].noteOnFrame < targetFrame) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  int _lowerBoundByOff(int targetFrame) {
    var lo = 0;
    var hi = _sortedByOff.length;
    while (lo < hi) {
      final mid = (lo + hi) >> LookaheadPlaybackConstants.binaryTreeLeftShift;
      if (_sortedByOff[mid].rawNoteOffFrame < targetFrame) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }
}
