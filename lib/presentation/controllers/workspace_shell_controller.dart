/// Layer 5 controller owning the active `ScoreEditingCommandBus`, project
/// open/close/reload lifecycle, hardware-aware playback attachment, and
/// typed score/mixer/map command dispatching.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ChangeNotifier;
import 'package:uuid/uuid.dart';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/commands/score_editing_command_bus.dart';
import '../../domain/models/score_models.dart';
import '../../domain/notation/crisp_score_mapper.dart';
import '../../domain/notation/dual_model_score_service.dart';
import '../../domain/playback/lookahead_playback_coordinator.dart';
import '../../domain/repositories/storage_contracts.dart';
import '../../domain/timeline/tempo_timeline_calculator.dart';
import '../theme/muse_presentation_constants.dart';
import 'audio_session_contract.dart';

/// Factory signature for constructing the active workspace's [IScoreEditingCommandBus].
typedef ScoreEditingCommandBusFactory = IScoreEditingCommandBus Function({
  required ScoreWorkspaceState initialState,
  required IProjectRepository projectRepository,
  required IDualModelScoreService dualModelService,
  required ILookaheadPlaybackCoordinator playbackCoordinator,
});

/// Immutable UI snapshot for [WorkspaceShellController].
final class WorkspaceShellState {
  final ScoreWorkspaceState? workspace;
  final IScoreEditingCommandBus? commandBus;
  final PartId? selectedPartId;
  final bool canUndo;
  final bool canRedo;
  final bool isOpening;
  final MuseError? lastError;

  const WorkspaceShellState({
    this.workspace,
    this.commandBus,
    this.selectedPartId,
    this.canUndo = false,
    this.canRedo = false,
    this.isOpening = false,
    this.lastError,
  });

  WorkspaceShellState copyWith({
    ScoreWorkspaceState? workspace,
    bool clearWorkspace = false,
    IScoreEditingCommandBus? commandBus,
    bool clearCommandBus = false,
    PartId? selectedPartId,
    bool clearSelectedPartId = false,
    bool? canUndo,
    bool? canRedo,
    bool? isOpening,
    MuseError? lastError,
    bool clearLastError = false,
  }) => WorkspaceShellState(
    workspace: clearWorkspace ? null : (workspace ?? this.workspace),
    commandBus: clearCommandBus ? null : (commandBus ?? this.commandBus),
    selectedPartId: clearSelectedPartId
        ? null
        : (selectedPartId ?? this.selectedPartId),
    canUndo: canUndo ?? this.canUndo,
    canRedo: canRedo ?? this.canRedo,
    isOpening: isOpening ?? this.isOpening,
    lastError: clearLastError ? null : (lastError ?? this.lastError),
  );
}

/// Manages active project lifecycle, serialized command bus ownership, and
/// audio engine project attachment strictly downward onto L4/Bridge.
final class WorkspaceShellController extends ChangeNotifier {
  final IProjectRepository _projectRepository;
  final IDualModelScoreService _dualModelScoreService;
  final ILookaheadPlaybackCoordinator _playbackCoordinator;
  final IAudioSessionController _audioSessionController;
  final ScoreEditingCommandBusFactory _commandBusFactory;
  final String Function() _uuidV7Generator;
  final int Function() _nowEpochMs;

  WorkspaceShellState _state = const WorkspaceShellState();
  StreamSubscription<ScoreWorkspaceState>? _busStateSub;
  bool _isDisposed = false;

  WorkspaceShellController({
    required this._projectRepository,
    required this._dualModelScoreService,
    required this._playbackCoordinator,
    required this._audioSessionController,
    ScoreEditingCommandBusFactory? commandBusFactory,
    String Function()? uuidV7Generator,
    int Function()? nowEpochMs,
  }) : _commandBusFactory =
           commandBusFactory ?? _defaultCommandBusFactory,
       _uuidV7Generator = uuidV7Generator ?? (() => const Uuid().v7()),
       _nowEpochMs =
           nowEpochMs ?? (() => DateTime.now().toUtc().millisecondsSinceEpoch);

  static IScoreEditingCommandBus _defaultCommandBusFactory({
    required ScoreWorkspaceState initialState,
    required IProjectRepository projectRepository,
    required IDualModelScoreService dualModelService,
    required ILookaheadPlaybackCoordinator playbackCoordinator,
  }) => ScoreEditingCommandBus(
    initialState: initialState,
    projectRepository: projectRepository,
    dualModelService: dualModelService,
    playbackCoordinator: playbackCoordinator,
  );

  WorkspaceShellState get state => _state;

  /// Returns the live authoritative workspace synchronously from the active
  /// command bus when open so playback/recording state providers reading this
  /// getter during command execution never observe stale pre-stream state.
  ScoreWorkspaceState? get currentWorkspace =>
      _state.commandBus?.currentState ?? _state.workspace;

  ScoreWorkspaceState? get workspace => currentWorkspace;

  Set<SoundFontId> get activeUsedSoundFontIds =>
      currentWorkspace?.aggregate.parts
          .map((part) => part.sfId)
          .whereType<SoundFontId>()
          .toSet() ??
      const <SoundFontId>{};

  Future<Result<ScoreWorkspaceState>> openProject(ProjectId projectId) async {
    if (_state.workspace != null || _state.commandBus != null) {
      await closeProject();
    }

    _emit(_state.copyWith(isOpening: true, clearLastError: true));

    final aggResult = await _projectRepository.loadProjectAggregate(projectId);
    if (aggResult case Err<ProjectWorkspaceAggregate>(:final error)) {
      _emit(_state.copyWith(isOpening: false, lastError: error));
      return Err(error);
    }
    final aggregate = (aggResult as Ok<ProjectWorkspaceAggregate>).value;

    final buildResult = _dualModelScoreService.buildWorkspaceState(aggregate);
    if (buildResult case Err<ScoreWorkspaceState>(:final error)) {
      _emit(_state.copyWith(isOpening: false, lastError: error));
      return Err(error);
    }
    final initialState = (buildResult as Ok<ScoreWorkspaceState>).value;

    final bus = _commandBusFactory(
      initialState: initialState,
      projectRepository: _projectRepository,
      dualModelService: _dualModelScoreService,
      playbackCoordinator: _playbackCoordinator,
    );

    _busStateSub = bus.stateStream.listen((nextWorkspace) {
      final existingSelection = _state.selectedPartId;
      final selectionStillPresent = existingSelection != null &&
          nextWorkspace.aggregate.parts.any(
            (part) => part.partId == existingSelection,
          );
      final nextSelectedPartId = selectionStillPresent
          ? existingSelection
          : nextWorkspace.aggregate.parts.firstOrNull?.partId;
      _emit(
        _state.copyWith(
          workspace: nextWorkspace,
          selectedPartId: nextSelectedPartId,
          clearSelectedPartId: nextSelectedPartId == null,
          canUndo: bus.canUndo,
          canRedo: bus.canRedo,
        ),
      );
    });

    final initialSelectedPartId =
        initialState.aggregate.parts.firstOrNull?.partId;
    final sessionStatus = _audioSessionController.audioSessionStatus.value;

    if (sessionStatus.phase == AudioSessionPhase.ready) {
      final attachResult = await _playbackCoordinator.attachProject(
        initialState,
      );
      if (attachResult case Err<void>(:final error)) {
        if (error.code == MuseErrorCode.missingSoundFontForPart) {
          // Keep workspace open in edit-inspect mode so the user can assign a
          // replacement SoundFont in PartMixerSidebar and re-attach.
          _emit(
            _state.copyWith(
              workspace: initialState,
              commandBus: bus,
              selectedPartId: initialSelectedPartId,
              clearSelectedPartId: initialSelectedPartId == null,
              canUndo: bus.canUndo,
              canRedo: bus.canRedo,
              isOpening: false,
              lastError: error,
            ),
          );
          return Err(error);
        }

        await _disposeBusAndDetach(bus);
        _emit(
          _state.copyWith(
            clearWorkspace: true,
            clearCommandBus: true,
            clearSelectedPartId: true,
            canUndo: false,
            canRedo: false,
            isOpening: false,
            lastError: error,
          ),
        );
        return Err(error);
      }
    }

    _emit(
      _state.copyWith(
        workspace: initialState,
        commandBus: bus,
        selectedPartId: initialSelectedPartId,
        clearSelectedPartId: initialSelectedPartId == null,
        canUndo: bus.canUndo,
        canRedo: bus.canRedo,
        isOpening: false,
        clearLastError: true,
      ),
    );
    return Ok(initialState);
  }

  Future<void> closeProject() async {
    final bus = _state.commandBus;
    await _disposeBusAndDetach(bus);
    _emit(
      _state.copyWith(
        clearWorkspace: true,
        clearCommandBus: true,
        clearSelectedPartId: true,
        canUndo: false,
        canRedo: false,
        isOpening: false,
        clearLastError: true,
      ),
    );
  }

  Future<Result<void>> reloadProjectById(ProjectId projectId) async {
    final result = await openProject(projectId);
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return Err(error);
    }
    return const Ok(null);
  }

  Future<Result<void>> ensureAudioInitializedAndAttach() async {
    final initResult = await _audioSessionController.ensureAudioInitialized();
    if (initResult case Err<AudioHardwareInfo>(:final error)) {
      _emit(_state.copyWith(lastError: error));
      return Err(error);
    }
    final activeWorkspace = _state.workspace;
    if (activeWorkspace != null) {
      final attachResult = await _playbackCoordinator.attachProject(
        activeWorkspace,
      );
      if (attachResult case Err<void>(:final error)) {
        _emit(_state.copyWith(lastError: error));
        return Err(error);
      }
    }
    _emit(_state.copyWith(clearLastError: true));
    return const Ok(null);
  }

  void selectPart(PartId partId) {
    final activeWorkspace = _state.workspace;
    if (activeWorkspace == null) {
      return;
    }
    if (!activeWorkspace.aggregate.parts.any((part) => part.partId == partId)) {
      return;
    }
    if (_state.selectedPartId == partId) {
      return;
    }
    _emit(_state.copyWith(selectedPartId: partId));
  }

  ITempoTimelineCalculator? buildTimelineCalculatorForActiveWorkspace() {
    final activeWorkspace = currentWorkspace;
    if (activeWorkspace == null) {
      return null;
    }
    final agg = activeWorkspace.aggregate;
    return TempoTimelineCalculator(
      tempoEvents: agg.tempoEvents,
      timeSignatureEvents: agg.timeSignatureEvents,
      pickupTicks: agg.project.pickupTicks,
    );
  }

  Future<void> syncCommittedTake(AudioTakeEntity take) async {
    await _state.commandBus?.syncCommittedTake(take);
  }

  Future<void> syncRealignedTakes(List<AudioTakeEntity> takes) async {
    await _state.commandBus?.syncRealignedTakes(takes);
  }

  Future<T> runSerializedIfActive<T>(Future<T> Function() action) {
    final bus = _state.commandBus;
    if (bus != null) {
      return bus.runSerialized(action);
    }
    return action();
  }

  Future<Result<ScoreWorkspaceState>> executeScoreCommand(
    ScoreCommand command,
  ) async {
    final bus = _state.commandBus;
    if (bus == null) {
      return _noActiveWorkspaceErr();
    }
    final previousErrorCode = _state.lastError?.code;
    final result = await bus.execute(command);
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      _emit(_state.copyWith(lastError: error));
      return Err(error);
    }
    final updated = (result as Ok<ScoreWorkspaceState>).value;
    if (previousErrorCode == MuseErrorCode.missingSoundFontForPart &&
        _audioSessionController.audioSessionStatus.value.phase ==
            AudioSessionPhase.ready) {
      final reattachResult = await _playbackCoordinator.attachProject(updated);
      if (reattachResult case Err<void>(:final error)) {
        _emit(_state.copyWith(lastError: error));
        return Ok(updated);
      }
    }
    _emit(_state.copyWith(clearLastError: true));
    return Ok(updated);
  }

  Future<Result<ScoreWorkspaceState>> undo() async {
    final bus = _state.commandBus;
    if (bus == null) {
      return _noActiveWorkspaceErr();
    }
    final result = await bus.undo();
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      _emit(_state.copyWith(lastError: error));
      return Err(error);
    }
    _emit(_state.copyWith(clearLastError: true));
    return result;
  }

  Future<Result<ScoreWorkspaceState>> redo() async {
    final bus = _state.commandBus;
    if (bus == null) {
      return _noActiveWorkspaceErr();
    }
    final result = await bus.redo();
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      _emit(_state.copyWith(lastError: error));
      return Err(error);
    }
    _emit(_state.copyWith(clearLastError: true));
    return result;
  }

  Future<Result<ScoreWorkspaceState>> updateProjectSettings({
    String? title,
    int? gridSnapTicks,
    int? pickupTicks,
    PlaybackTimingMode? playbackTimingMode,
  }) => executeScoreCommand(
    UpdateProjectSettingsCommand(
      title: title,
      gridSnapTicks: gridSnapTicks,
      pickupTicks: pickupTicks,
      playbackTimingMode: playbackTimingMode,
    ),
  );

  Future<Result<ScoreWorkspaceState>> addPart({
    required String name,
    required int stavesCount,
    required SoundFontId? sfId,
    required int bankNum,
    required int programNum,
    required ClefSign initialClefSign,
    required int initialClefLine,
    bool isPercussion = false,
  }) async {
    final activeWorkspace = _state.workspace;
    if (activeWorkspace == null || _state.commandBus == null) {
      return _noActiveWorkspaceErr();
    }

    final agg = activeWorkspace.aggregate;
    final usedChannels = agg.parts.map((part) => part.midiChannel).toSet();
    final int midiChannel;
    if (isPercussion) {
      midiChannel = MuseConstants.gmPercussionChannel;
    } else {
      int? candidate;
      for (
        var ch = MuseConstants.minMidiChannel;
        ch <= MuseConstants.maxMidiChannel;
        ch++
      ) {
        if (ch == MuseConstants.gmPercussionChannel) {
          continue;
        }
        if (!usedChannels.contains(ch)) {
          candidate = ch;
          break;
        }
      }
      if (candidate == null) {
        const err = MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'All non-percussion MIDI channels (0..15 excluding Ch 9) are in use.',
        );
        _emit(_state.copyWith(lastError: err));
        return const Err(err);
      }
      midiChannel = candidate;
    }

    final existingXmlIds = agg.parts
        .map((part) => part.musicXmlPartId)
        .toSet();
    var seq = MusePresentationConstants.firstPartSequenceNumber;
    while (existingXmlIds.contains(
      '${MusePresentationConstants.musicXmlPartIdPrefix}$seq',
    )) {
      seq += 1;
    }
    final musicXmlPartId =
        '${MusePresentationConstants.musicXmlPartIdPrefix}$seq';

    final maxSortOrder = agg.parts.isEmpty
        ? MusePresentationConstants.initialPartSortOrder - 1
        : agg.parts.map((part) => part.sortOrder).reduce(math.max);
    final now = _nowEpochMs();
    final partId = PartId(_uuidV7Generator());

    final newPart = ProjectPartEntity(
      partId: partId,
      projectId: agg.project.projectId,
      musicXmlPartId: musicXmlPartId,
      sortOrder: maxSortOrder + 1,
      name: name,
      stavesCount: stavesCount,
      midiChannel: midiChannel,
      sfId: sfId,
      bankNum: bankNum,
      programNum: programNum,
      gainDb: CrispScoreMapperConstants.defaultGainDb,
      pan: CrispScoreMapperConstants.defaultPan,
      isMuted: false,
      isSolo: false,
      updatedAtMs: now,
    );

    final clefs = <ClefEventEntity>[
      ClefEventEntity(
        clefEventId: ClefEventId(_uuidV7Generator()),
        projectId: agg.project.projectId,
        partId: partId,
        staffNumber: MusePresentationConstants.singleStaffNumber,
        tick: const Tick(MusePresentationConstants.initialTick),
        sign: initialClefSign,
        line: initialClefLine,
        octaveChange: MusePresentationConstants.defaultClefOctaveChange,
        updatedAtMs: now,
      ),
      if (stavesCount == CrispScoreMapperConstants.grandStaffCount)
        ClefEventEntity(
          clefEventId: ClefEventId(_uuidV7Generator()),
          projectId: agg.project.projectId,
          partId: partId,
          staffNumber: MusePresentationConstants.grandStaffLowerNumber,
          tick: const Tick(MusePresentationConstants.initialTick),
          sign: ClefSign.F,
          line: CrispScoreMapperConstants.bassClefLine,
          octaveChange: MusePresentationConstants.defaultClefOctaveChange,
          updatedAtMs: now,
        ),
    ];

    final result = await executeScoreCommand(
      AddProjectPartCommand(part: newPart, initialClefs: clefs),
    );
    if (result.isOk) {
      _emit(_state.copyWith(selectedPartId: partId));
    }
    return result;
  }

  Future<Result<ScoreWorkspaceState>> updatePartMixerOrPatch(
    ProjectPartEntity updatedPart,
  ) => executeScoreCommand(UpdatePartMixerOrPatchCommand(updatedPart));

  Future<Result<ScoreWorkspaceState>> reorderParts(
    List<PartId> orderedPartIds,
  ) => executeScoreCommand(ReorderProjectPartsCommand(orderedPartIds));

  Future<Result<ScoreWorkspaceState>> removePart(PartId partId) async {
    final result = await executeScoreCommand(RemoveProjectPartCommand(partId));
    if (result case Ok<ScoreWorkspaceState>(:final value)) {
      final remainingSelection = _state.selectedPartId;
      final stillExists =
          remainingSelection != null &&
          value.aggregate.parts.any((p) => p.partId == remainingSelection);
      if (!stillExists) {
        final fallback = value.aggregate.parts.firstOrNull?.partId;
        _emit(
          _state.copyWith(
            selectedPartId: fallback,
            clearSelectedPartId: fallback == null,
          ),
        );
      }
    }
    return result;
  }

  Future<Result<ScoreWorkspaceState>> clearPartAudio(PartId partId) =>
      executeScoreCommand(ClearPartAudioCommand(partId));

  Future<void> _disposeBusAndDetach(IScoreEditingCommandBus? bus) async {
    await _busStateSub?.cancel();
    _busStateSub = null;
    await _playbackCoordinator.detachProject();
    if (bus != null) {
      await bus.dispose();
    }
  }

  Result<ScoreWorkspaceState> _noActiveWorkspaceErr() {
    const err = MuseError(
      MuseErrorCode.entityNotFound,
      'No active project workspace is open.',
    );
    _emit(_state.copyWith(lastError: err));
    return const Err(err);
  }

  void _emit(WorkspaceShellState next) {
    _state = next;
    if (!_isDisposed) {
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _isDisposed = true;
    final bus = _state.commandBus;
    _state = const WorkspaceShellState();
    unawaited(_disposeBusAndDetach(bus));
    super.dispose();
  }
}
