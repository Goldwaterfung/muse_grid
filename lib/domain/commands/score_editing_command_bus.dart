/// Pure Dart reversible score editing command bus (`IScoreEditingCommandBus`),
/// fail-closed validation, atomic SQLite persistence, Undo/Redo stacks, and
/// live lookahead playback invalidation notifications.
library;

import 'dart:async';
import 'dart:collection';
import 'dart:math' as math;

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../models/score_models.dart';
import '../notation/crisp_score_mapper.dart';
import '../notation/dual_model_score_service.dart';
import '../playback/lookahead_playback_coordinator.dart';
import '../repositories/storage_contracts.dart';
import '../timeline/tempo_timeline_calculator.dart';

/// Base sealed union of all 19 reversible score editing commands.
sealed class ScoreCommand {
  const ScoreCommand();
}

final class InsertNotesCommand extends ScoreCommand {
  final List<TimelineNote> notes;

  const InsertNotesCommand(this.notes);
}

final class UpdateNotesCommand extends ScoreCommand {
  final List<TimelineNote> updatedNotes;

  const UpdateNotesCommand(this.updatedNotes);
}

final class DeleteNotesCommand extends ScoreCommand {
  final List<NoteId> noteIds;

  const DeleteNotesCommand(this.noteIds);
}

final class UpsertNoteSpannerCommand extends ScoreCommand {
  final NoteSpannerEntity spanner;

  const UpsertNoteSpannerCommand(this.spanner);
}

final class DeleteNoteSpannerCommand extends ScoreCommand {
  final SpannerId spannerId;

  const DeleteNoteSpannerCommand(this.spannerId);
}

final class UpsertTempoEventCommand extends ScoreCommand {
  final TempoEventEntity event;

  const UpsertTempoEventCommand(this.event);
}

final class DeleteTempoEventCommand extends ScoreCommand {
  final TempoEventId tempoEventId;

  const DeleteTempoEventCommand(this.tempoEventId);
}

final class UpsertTimeSignatureCommand extends ScoreCommand {
  final TimeSignatureEventEntity event;

  const UpsertTimeSignatureCommand(this.event);
}

final class DeleteTimeSignatureCommand extends ScoreCommand {
  final TimeSigEventId tsEventId;

  const DeleteTimeSignatureCommand(this.tsEventId);
}

final class UpsertKeySignatureCommand extends ScoreCommand {
  final KeySignatureEventEntity event;

  const UpsertKeySignatureCommand(this.event);
}

final class DeleteKeySignatureCommand extends ScoreCommand {
  final KeySigEventId keyEventId;

  const DeleteKeySignatureCommand(this.keyEventId);
}

final class UpsertClefEventCommand extends ScoreCommand {
  final ClefEventEntity event;

  const UpsertClefEventCommand(this.event);
}

final class DeleteClefEventCommand extends ScoreCommand {
  final ClefEventId clefEventId;

  const DeleteClefEventCommand(this.clefEventId);
}

final class AddProjectPartCommand extends ScoreCommand {
  final ProjectPartEntity part;
  final List<ClefEventEntity> initialClefs;

  const AddProjectPartCommand({required this.part, required this.initialClefs});
}

final class UpdatePartMixerOrPatchCommand extends ScoreCommand {
  final ProjectPartEntity updatedPart;

  const UpdatePartMixerOrPatchCommand(this.updatedPart);
}

final class ReorderProjectPartsCommand extends ScoreCommand {
  final List<PartId> orderedPartIds;

  const ReorderProjectPartsCommand(this.orderedPartIds);
}

final class RemoveProjectPartCommand extends ScoreCommand {
  final PartId partId;

  const RemoveProjectPartCommand(this.partId);
}

final class ClearPartAudioCommand extends ScoreCommand {
  final PartId partId;

  const ClearPartAudioCommand(this.partId);
}

final class UpdateProjectSettingsCommand extends ScoreCommand {
  final String? title;
  final int? gridSnapTicks;
  final int? pickupTicks;
  final PlaybackTimingMode? playbackTimingMode;

  const UpdateProjectSettingsCommand({
    this.title,
    this.gridSnapTicks,
    this.pickupTicks,
    this.playbackTimingMode,
  });
}

/// Pure Dart contract for serialized reversible score editing, Undo/Redo, and
/// workspace state broadcasting to L5 UI controllers.
abstract interface class IScoreEditingCommandBus {
  ScoreWorkspaceState get currentState;

  Stream<ScoreWorkspaceState> get stateStream;

  bool get canUndo;

  bool get canRedo;

  Future<Result<ScoreWorkspaceState>> execute(ScoreCommand command);

  Future<Result<ScoreWorkspaceState>> undo();

  Future<Result<ScoreWorkspaceState>> redo();

  Future<T> runSerialized<T>(Future<T> Function() action);

  Future<void> syncCommittedTake(AudioTakeEntity take);

  Future<void> syncRealignedTakes(List<AudioTakeEntity> takes);

  Future<void> dispose();
}

final class _MetadataPatch {
  final String? title;
  final int? gridSnapTicks;
  final int? pickupTicks;
  final PlaybackTimingMode? playbackTimingMode;

  const _MetadataPatch({
    this.title,
    this.gridSnapTicks,
    this.pickupTicks,
    this.playbackTimingMode,
  });

  UpdateProjectMetadataInput toInput({
    required ProjectId projectId,
    required int expectedRevision,
  }) => UpdateProjectMetadataInput(
    projectId: projectId,
    expectedRevision: expectedRevision,
    title: title,
    gridSnapTicks: gridSnapTicks,
    pickupTicks: pickupTicks,
    playbackTimingMode: playbackTimingMode,
  );
}

final class _MutationDelta {
  final _MetadataPatch? metadataPatch;
  final List<ProjectPartEntity> upsertParts;
  final List<PartId> deletePartIds;
  final List<TempoEventEntity> upsertTempoEvents;
  final List<TempoEventId> deleteTempoEventIds;
  final List<TimeSignatureEventEntity> upsertTimeSignatureEvents;
  final List<TimeSigEventId> deleteTimeSignatureEventIds;
  final List<KeySignatureEventEntity> upsertKeySignatureEvents;
  final List<KeySigEventId> deleteKeySignatureEventIds;
  final List<ClefEventEntity> upsertClefEvents;
  final List<ClefEventId> deleteClefEventIds;
  final List<TimelineNote> upsertNotes;
  final List<NoteId> deleteNoteIds;
  final List<NoteSpannerEntity> upsertSpanners;
  final List<SpannerId> deleteSpannerIds;
  final List<AudioTakeEntity> upsertAudioTakes;
  final List<PartId> deleteAudioTakePartIds;

  const _MutationDelta({
    this.metadataPatch,
    this.upsertParts = const [],
    this.deletePartIds = const [],
    this.upsertTempoEvents = const [],
    this.deleteTempoEventIds = const [],
    this.upsertTimeSignatureEvents = const [],
    this.deleteTimeSignatureEventIds = const [],
    this.upsertKeySignatureEvents = const [],
    this.deleteKeySignatureEventIds = const [],
    this.upsertClefEvents = const [],
    this.deleteClefEventIds = const [],
    this.upsertNotes = const [],
    this.deleteNoteIds = const [],
    this.upsertSpanners = const [],
    this.deleteSpannerIds = const [],
    this.upsertAudioTakes = const [],
    this.deleteAudioTakePartIds = const [],
  });

  ScoreMutationBatch toBatch({
    required ProjectId projectId,
    required int expectedRevision,
  }) => ScoreMutationBatch(
    projectId: projectId,
    expectedRevision: expectedRevision,
    projectMetadataUpdate: metadataPatch?.toInput(
      projectId: projectId,
      expectedRevision: expectedRevision,
    ),
    upsertParts: upsertParts,
    deletePartIds: deletePartIds,
    upsertTempoEvents: upsertTempoEvents,
    deleteTempoEventIds: deleteTempoEventIds,
    upsertTimeSignatureEvents: upsertTimeSignatureEvents,
    deleteTimeSignatureEventIds: deleteTimeSignatureEventIds,
    upsertKeySignatureEvents: upsertKeySignatureEvents,
    deleteKeySignatureEventIds: deleteKeySignatureEventIds,
    upsertClefEvents: upsertClefEvents,
    deleteClefEventIds: deleteClefEventIds,
    upsertNotes: upsertNotes,
    deleteNoteIds: deleteNoteIds,
    upsertSpanners: upsertSpanners,
    deleteSpannerIds: deleteSpannerIds,
    upsertAudioTakes: upsertAudioTakes,
    deleteAudioTakePartIds: deleteAudioTakePartIds,
  );
}

final class _UndoRedoEntry {
  final _MutationDelta forward;
  final _MutationDelta inverse;
  final Tick affectedStartTick;
  final Tick affectedEndTick;
  final bool affectsPlayback;

  const _UndoRedoEntry({
    required this.forward,
    required this.inverse,
    required this.affectedStartTick,
    required this.affectedEndTick,
    required this.affectsPlayback,
  });
}

/// Serialized, fail-closed command bus coordinating SQLite persistence,
/// `DualModelScoreService`, bounded Undo/Redo history, and playback invalidation.
final class ScoreEditingCommandBus implements IScoreEditingCommandBus {
  static const int defaultMaxHistoryDepth = 200;
  static const int minHistoryDepth = 1;
  static const int initialMapTick = TempoTimelineCalculator.minTick;
  static const int revisionStep = 1;
  static const int trailingRangeMarginTicks = 1;
  static const int minDurationTicks = 1;
  static const int minTempoUsPerQuarter = 1;
  static const int minSortOrder = 0;
  static const int minStaffNumber = CrispScoreMapperConstants.defaultStaffNumber;
  static const int minVoiceNumber = CrispScoreMapperConstants.minVoiceNumber;
  static const int maxVoiceNumber = CrispScoreMapperConstants.maxVoiceNumber;
  static const int minEnharmonicAlter = -2;
  static const int maxEnharmonicAlter = 2;
  static const int minSpannerLevel = 1;
  static const int maxSpannerLevel = 6;
  static const int minClefLine = 1;
  static const int maxClefLine = 5;
  static const int minClefOctaveChange = -2;
  static const int maxClefOctaveChange = 2;
  static const int minKeySigStaffNumber =
      CrispScoreMapperConstants.allStavesKeySigStaffNumber;
  static const int maxKeySigStaffNumber =
      CrispScoreMapperConstants.grandStaffCount;
  static const int minKeySigFifths =
      CrispScoreMapperConstants.minKeySignatureFifths;
  static const int maxKeySigFifths =
      CrispScoreMapperConstants.maxKeySignatureFifths;
  static const int minStavesCount = CrispScoreMapperConstants.singleStaffCount;
  static const int maxStavesCount = CrispScoreMapperConstants.grandStaffCount;
  static const double minPan = -1.0;
  static const double maxPan = 1.0;
  static const int minNonEmptyLength = 1;
  static const int singleInitialEventCount = 1;

  final IProjectRepository _projectRepository;
  final IDualModelScoreService _dualModelService;
  final ILookaheadPlaybackCoordinator? _playbackCoordinator;
  final int _maxHistoryDepth;

  final StreamController<ScoreWorkspaceState> _stateController =
      StreamController<ScoreWorkspaceState>.broadcast();
  final ListQueue<_UndoRedoEntry> _undoStack = ListQueue<_UndoRedoEntry>();
  final ListQueue<_UndoRedoEntry> _redoStack = ListQueue<_UndoRedoEntry>();

  static final Object _serializedZoneKey = Object();

  ScoreWorkspaceState _currentState;
  Future<void> _serialTail = Future<void>.value();
  bool _isDisposed = false;

  ScoreEditingCommandBus({
    required ScoreWorkspaceState initialState,
    required this._projectRepository,
    required this._dualModelService,
    this._playbackCoordinator,
    int maxHistoryDepth = defaultMaxHistoryDepth,
  }) : _currentState = initialState,
       _maxHistoryDepth = maxHistoryDepth {
    if (maxHistoryDepth < minHistoryDepth) {
      throw ArgumentError.value(
        maxHistoryDepth,
        'maxHistoryDepth',
        'Must be >= $minHistoryDepth',
      );
    }
  }

  @override
  ScoreWorkspaceState get currentState => _currentState;

  @override
  Stream<ScoreWorkspaceState> get stateStream => _stateController.stream;

  @override
  bool get canUndo => _undoStack.isNotEmpty;

  @override
  bool get canRedo => _redoStack.isNotEmpty;

  @override
  Future<Result<ScoreWorkspaceState>> execute(ScoreCommand command) {
    return _enqueueSerialized(() async {
      if (_isDisposed) {
        return const Err<ScoreWorkspaceState>(
          MuseError(
            MuseErrorCode.entityNotFound,
            'ScoreEditingCommandBus has been disposed',
          ),
        );
      }

      final compileResult = _compileCommand(command, _currentState.aggregate);
      if (compileResult case Err(:final error)) {
        return Err<ScoreWorkspaceState>(error);
      }
      final entry = (compileResult as Ok<_UndoRedoEntry>).value;

      final commitResult = await _commitDelta(entry.forward);
      if (commitResult case Err(:final error)) {
        return Err<ScoreWorkspaceState>(error);
      }
      final nextState = (commitResult as Ok<ScoreWorkspaceState>).value;

      _currentState = nextState;
      _pushBounded(_undoStack, entry);
      _redoStack.clear();
      _emitAndNotifyPlayback(entry);
      return Ok<ScoreWorkspaceState>(nextState);
    });
  }

  @override
  Future<Result<ScoreWorkspaceState>> undo() {
    return _enqueueSerialized(() async {
      if (_isDisposed || _undoStack.isEmpty) {
        return const Err<ScoreWorkspaceState>(
          MuseError(MuseErrorCode.entityNotFound, 'Nothing available to undo'),
        );
      }

      final entry = _undoStack.last;
      final commitResult = await _commitDelta(entry.inverse);
      if (commitResult case Err(:final error)) {
        return Err<ScoreWorkspaceState>(error);
      }
      final nextState = (commitResult as Ok<ScoreWorkspaceState>).value;

      _undoStack.removeLast();
      _pushBounded(_redoStack, entry);
      _currentState = nextState;
      _emitAndNotifyPlayback(entry);
      return Ok<ScoreWorkspaceState>(nextState);
    });
  }

  @override
  Future<Result<ScoreWorkspaceState>> redo() {
    return _enqueueSerialized(() async {
      if (_isDisposed || _redoStack.isEmpty) {
        return const Err<ScoreWorkspaceState>(
          MuseError(MuseErrorCode.entityNotFound, 'Nothing available to redo'),
        );
      }

      final entry = _redoStack.last;
      final commitResult = await _commitDelta(entry.forward);
      if (commitResult case Err(:final error)) {
        return Err<ScoreWorkspaceState>(error);
      }
      final nextState = (commitResult as Ok<ScoreWorkspaceState>).value;

      _redoStack.removeLast();
      _pushBounded(_undoStack, entry);
      _currentState = nextState;
      _emitAndNotifyPlayback(entry);
      return Ok<ScoreWorkspaceState>(nextState);
    });
  }

  @override
  Future<T> runSerialized<T>(Future<T> Function() action) =>
      _enqueueSerializedAction(action);

  /// Synchronizes an externally committed [AudioTakeEntity] (saved via
  /// `IProjectRepository.promoteAndCommitRecordedTake`) into the L4 dual model
  /// on the serialized bus queue so it never races with in-flight commands.
  @override
  Future<void> syncCommittedTake(AudioTakeEntity take) {
    if (_isDisposed) {
      return Future<void>.value();
    }
    return _enqueueSerializedAction<void>(() async {
      if (_isDisposed) {
        return;
      }
      final currentProject = _currentState.aggregate.project;
      if (take.projectId != currentProject.projectId) {
        return;
      }
      _applyCommittedAudioTakesSync(<AudioTakeEntity>[take]);
    });
  }

  /// Synchronizes realigned [AudioTakeEntity] rows (saved via
  /// `IProjectRepository.realignAudioTakesCalibration`) into the L4 dual model
  /// on the serialized bus queue so it never races with in-flight commands.
  @override
  Future<void> syncRealignedTakes(List<AudioTakeEntity> takes) {
    if (_isDisposed || takes.isEmpty) {
      return Future<void>.value();
    }
    return _enqueueSerializedAction<void>(() async {
      if (_isDisposed) {
        return;
      }
      final currentProjectId = _currentState.aggregate.project.projectId;
      final matchingTakes = takes
          .where((t) => t.projectId == currentProjectId)
          .toList(growable: false);
      if (matchingTakes.isEmpty) {
        return;
      }
      _applyCommittedAudioTakesSync(matchingTakes);
    });
  }

  @override
  Future<void> dispose() async {
    _isDisposed = true;
    await _serialTail;
    await _stateController.close();
  }

  void _applyCommittedAudioTakesSync(List<AudioTakeEntity> takes) {
    final currentProject = _currentState.aggregate.project;
    final batch = ScoreMutationBatch(
      projectId: currentProject.projectId,
      expectedRevision: currentProject.revision,
      upsertAudioTakes: takes,
    );
    final result = _dualModelService.applyMutationToDualModel(
      _currentState,
      batch,
    );
    if (result case Ok(:final value)) {
      _currentState = value;
      if (!_stateController.isClosed) {
        _stateController.add(value);
      }
    }
  }

  Future<Result<ScoreWorkspaceState>> _enqueueSerialized(
    Future<Result<ScoreWorkspaceState>> Function() task,
  ) => _enqueueSerializedAction(task);

  Future<T> _enqueueSerializedAction<T>(Future<T> Function() task) {
    if (identical(Zone.current[_serializedZoneKey], this)) {
      return task();
    }
    final completer = Completer<T>();
    _serialTail = _serialTail.then((_) async {
      try {
        final result = await runZoned(
          task,
          zoneValues: <Object?, Object?>{_serializedZoneKey: this},
        );
        completer.complete(result);
      } catch (error, stackTrace) {
        completer.completeError(error, stackTrace);
      }
    });
    return completer.future;
  }

  Future<Result<ScoreWorkspaceState>> _commitDelta(_MutationDelta delta) async {
    final project = _currentState.aggregate.project;
    final batch = delta.toBatch(
      projectId: project.projectId,
      expectedRevision: project.revision,
    );

    final previewResult = _dualModelService.applyMutationToDualModel(
      _currentState,
      batch,
    );
    if (previewResult case Err(:final error)) {
      return Err<ScoreWorkspaceState>(error);
    }
    final nextState = (previewResult as Ok<ScoreWorkspaceState>).value;

    final commitResult = await _projectRepository.commitScoreMutationBatch(
      batch,
    );
    if (commitResult case Err(:final error)) {
      return Err<ScoreWorkspaceState>(error);
    }
    final committedRevision = (commitResult as Ok<int>).value;
    final expectedNextRevision = project.revision + revisionStep;
    if (committedRevision != expectedNextRevision) {
      return Err<ScoreWorkspaceState>(
        MuseError(
          MuseErrorCode.revisionConflict,
          'Committed revision $committedRevision does not match expected '
          '$expectedNextRevision',
        ),
      );
    }

    return Ok<ScoreWorkspaceState>(nextState);
  }

  void _pushBounded(ListQueue<_UndoRedoEntry> stack, _UndoRedoEntry entry) {
    stack.addLast(entry);
    while (stack.length > _maxHistoryDepth) {
      stack.removeFirst();
    }
  }

  void _emitAndNotifyPlayback(_UndoRedoEntry entry) {
    if (!_stateController.isClosed) {
      _stateController.add(_currentState);
    }
    if (entry.affectsPlayback) {
      _playbackCoordinator?.notifyScoreMutatedInRange(
        affectedStartTick: entry.affectedStartTick,
        affectedEndTick: entry.affectedEndTick,
      );
    }
  }

  Result<_UndoRedoEntry> _compileCommand(
    ScoreCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    return switch (command) {
      InsertNotesCommand c => _compileInsertNotes(c, agg),
      UpdateNotesCommand c => _compileUpdateNotes(c, agg),
      DeleteNotesCommand c => _compileDeleteNotes(c, agg),
      UpsertNoteSpannerCommand c => _compileUpsertSpanner(c, agg),
      DeleteNoteSpannerCommand c => _compileDeleteSpanner(c, agg),
      UpsertTempoEventCommand c => _compileUpsertTempoEvent(c, agg),
      DeleteTempoEventCommand c => _compileDeleteTempoEvent(c, agg),
      UpsertTimeSignatureCommand c => _compileUpsertTimeSignature(c, agg),
      DeleteTimeSignatureCommand c => _compileDeleteTimeSignature(c, agg),
      UpsertKeySignatureCommand c => _compileUpsertKeySignature(c, agg),
      DeleteKeySignatureCommand c => _compileDeleteKeySignature(c, agg),
      UpsertClefEventCommand c => _compileUpsertClefEvent(c, agg),
      DeleteClefEventCommand c => _compileDeleteClefEvent(c, agg),
      AddProjectPartCommand c => _compileAddProjectPart(c, agg),
      UpdatePartMixerOrPatchCommand c => _compileUpdatePartMixerOrPatch(c, agg),
      ReorderProjectPartsCommand c => _compileReorderProjectParts(c, agg),
      RemoveProjectPartCommand c => _compileRemoveProjectPart(c, agg),
      ClearPartAudioCommand c => _compileClearPartAudio(c, agg),
      UpdateProjectSettingsCommand c => _compileUpdateProjectSettings(c, agg),
    };
  }

  Result<_UndoRedoEntry> _compileInsertNotes(
    InsertNotesCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    if (command.notes.isEmpty) {
      return const Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'InsertNotesCommand requires at least one note',
        ),
      );
    }

    final partsById = _indexPartsById(agg);
    final existingNotesById = _indexNotesById(agg);
    final seenIds = <NoteId>{};
    final restoredNotes = <TimelineNote>[];
    final deleteInsertedIds = <NoteId>[];

    var minStart = command.notes.first.rawStartTick.value;
    var maxEnd = minStart;

    for (final note in command.notes) {
      if (!seenIds.add(note.noteId)) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'Duplicate NoteId (${note.noteId.value}) in InsertNotesCommand',
          ),
        );
      }
      final noteErr = _validateNote(note, agg.project.projectId, partsById);
      if (noteErr != null) {
        return Err<_UndoRedoEntry>(noteErr);
      }

      (minStart, maxEnd) = _expandSpanForNote(note, minStart, maxEnd);
      final prior = existingNotesById[note.noteId];
      if (prior != null) {
        restoredNotes.add(prior);
        (minStart, maxEnd) = _expandSpanForNote(prior, minStart, maxEnd);
      } else {
        deleteInsertedIds.add(note.noteId);
      }
    }

    final notesCopy = List<TimelineNote>.unmodifiable(command.notes);
    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(upsertNotes: notesCopy),
        inverse: _MutationDelta(
          upsertNotes: List<TimelineNote>.unmodifiable(restoredNotes),
          deleteNoteIds: List<NoteId>.unmodifiable(deleteInsertedIds),
        ),
        affectedStartTick: Tick(minStart),
        affectedEndTick: Tick(math.max(maxEnd, minStart + trailingRangeMarginTicks)),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileUpdateNotes(
    UpdateNotesCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    if (command.updatedNotes.isEmpty) {
      return const Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'UpdateNotesCommand requires at least one note',
        ),
      );
    }

    final partsById = _indexPartsById(agg);
    final existingNotesById = _indexNotesById(agg);
    final seenIds = <NoteId>{};
    final priorNotes = <TimelineNote>[];
    final targetPartByNoteId = <NoteId, PartId>{};
    var hasPartChange = false;

    var minStart = command.updatedNotes.first.rawStartTick.value;
    var maxEnd = minStart;

    for (final note in command.updatedNotes) {
      if (!seenIds.add(note.noteId)) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'Duplicate NoteId (${note.noteId.value}) in UpdateNotesCommand',
          ),
        );
      }
      final prior = existingNotesById[note.noteId];
      if (prior == null) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.entityNotFound,
            'Cannot update missing NoteId (${note.noteId.value})',
          ),
        );
      }
      final noteErr = _validateNote(note, agg.project.projectId, partsById);
      if (noteErr != null) {
        return Err<_UndoRedoEntry>(noteErr);
      }

      priorNotes.add(prior);
      targetPartByNoteId[note.noteId] = note.partId;
      if (prior.partId != note.partId) {
        hasPartChange = true;
      }
      (minStart, maxEnd) = _expandSpanForNote(prior, minStart, maxEnd);
      (minStart, maxEnd) = _expandSpanForNote(note, minStart, maxEnd);
    }

    final forwardUpsertSpanners = <NoteSpannerEntity>[];
    final forwardDeleteSpannerIds = <SpannerId>[];
    final inverseUpsertSpanners = <NoteSpannerEntity>[];
    if (hasPartChange) {
      for (final spanner in agg.spanners) {
        final targetStartPart = targetPartByNoteId[spanner.startNoteId];
        final targetEndPart = targetPartByNoteId[spanner.endNoteId];
        if (targetStartPart == null && targetEndPart == null) {
          continue;
        }
        final finalStartPart =
            targetStartPart ??
            existingNotesById[spanner.startNoteId]?.partId ??
            spanner.partId;
        final finalEndPart =
            targetEndPart ??
            existingNotesById[spanner.endNoteId]?.partId ??
            spanner.partId;
        if (finalStartPart == spanner.partId &&
            finalEndPart == spanner.partId) {
          continue;
        }
        inverseUpsertSpanners.add(spanner);
        if (finalStartPart == finalEndPart) {
          forwardUpsertSpanners.add(
            NoteSpannerEntity(
              spannerId: spanner.spannerId,
              projectId: spanner.projectId,
              partId: finalStartPart,
              spannerType: spanner.spannerType,
              startNoteId: spanner.startNoteId,
              endNoteId: spanner.endNoteId,
              spannerLevel: spanner.spannerLevel,
              placement: spanner.placement,
              updatedAtMs: spanner.updatedAtMs,
            ),
          );
        } else {
          forwardDeleteSpannerIds.add(spanner.spannerId);
        }
      }
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          upsertNotes: List<TimelineNote>.unmodifiable(command.updatedNotes),
          upsertSpanners: List<NoteSpannerEntity>.unmodifiable(
            forwardUpsertSpanners,
          ),
          deleteSpannerIds: List<SpannerId>.unmodifiable(
            forwardDeleteSpannerIds,
          ),
        ),
        inverse: _MutationDelta(
          upsertNotes: List<TimelineNote>.unmodifiable(priorNotes),
          upsertSpanners: List<NoteSpannerEntity>.unmodifiable(
            inverseUpsertSpanners,
          ),
        ),
        affectedStartTick: Tick(minStart),
        affectedEndTick: Tick(math.max(maxEnd, minStart + trailingRangeMarginTicks)),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileDeleteNotes(
    DeleteNotesCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    if (command.noteIds.isEmpty) {
      return const Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'DeleteNotesCommand requires at least one NoteId',
        ),
      );
    }

    final existingNotesById = _indexNotesById(agg);
    final uniqueNoteIds = <NoteId>{};
    final deletedNotes = <TimelineNote>[];

    var minStart = TempoTimelineCalculator.minTick;
    var maxEnd = TempoTimelineCalculator.minTick;
    var initializedSpan = false;

    for (final noteId in command.noteIds) {
      final existing = existingNotesById[noteId];
      if (existing == null) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.entityNotFound,
            'Cannot delete missing NoteId (${noteId.value})',
          ),
        );
      }
      if (!uniqueNoteIds.add(noteId)) {
        continue;
      }
      deletedNotes.add(existing);
      if (!initializedSpan) {
        minStart = math.min(
          existing.rawStartTick.value,
          existing.quantizedStartTick.value,
        );
        maxEnd = minStart;
        initializedSpan = true;
      }
      (minStart, maxEnd) = _expandSpanForNote(existing, minStart, maxEnd);
    }

    final dependentSpanners = agg.spanners
        .where(
          (s) =>
              uniqueNoteIds.contains(s.startNoteId) ||
              uniqueNoteIds.contains(s.endNoteId),
        )
        .toList(growable: false);

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          deleteNoteIds: List<NoteId>.unmodifiable(uniqueNoteIds),
        ),
        inverse: _MutationDelta(
          upsertNotes: List<TimelineNote>.unmodifiable(deletedNotes),
          upsertSpanners: List<NoteSpannerEntity>.unmodifiable(
            dependentSpanners,
          ),
        ),
        affectedStartTick: Tick(minStart),
        affectedEndTick: Tick(math.max(maxEnd, minStart + trailingRangeMarginTicks)),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileUpsertSpanner(
    UpsertNoteSpannerCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final spanner = command.spanner;
    if (spanner.projectId != agg.project.projectId) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Spanner projectId (${spanner.projectId.value}) does not match active project',
        ),
      );
    }
    if (spanner.spannerLevel < minSpannerLevel ||
        spanner.spannerLevel > maxSpannerLevel) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'spannerLevel (${spanner.spannerLevel}) must be in $minSpannerLevel..$maxSpannerLevel',
        ),
      );
    }

    final partsById = _indexPartsById(agg);
    if (!partsById.containsKey(spanner.partId)) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Spanner partId (${spanner.partId.value}) not found',
        ),
      );
    }

    final notesById = _indexNotesById(agg);
    final startNote = notesById[spanner.startNoteId];
    final endNote = notesById[spanner.endNoteId];
    if (startNote == null ||
        endNote == null ||
        startNote.partId != spanner.partId ||
        endNote.partId != spanner.partId) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Spanner startNoteId (${spanner.startNoteId.value}) or endNoteId '
          '(${spanner.endNoteId.value}) missing on part ${spanner.partId.value}',
        ),
      );
    }

    NoteSpannerEntity? prior;
    for (final existing in agg.spanners) {
      if (existing.spannerId == spanner.spannerId) {
        prior = existing;
        break;
      }
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(upsertSpanners: <NoteSpannerEntity>[spanner]),
        inverse: prior != null
            ? _MutationDelta(upsertSpanners: <NoteSpannerEntity>[prior])
            : _MutationDelta(deleteSpannerIds: <SpannerId>[spanner.spannerId]),
        affectedStartTick: startNote.quantizedStartTick,
        affectedEndTick: Tick(
          endNote.quantizedStartTick.value + endNote.quantizedDurationTicks,
        ),
        affectsPlayback: false,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileDeleteSpanner(
    DeleteNoteSpannerCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    NoteSpannerEntity? existing;
    for (final s in agg.spanners) {
      if (s.spannerId == command.spannerId) {
        existing = s;
        break;
      }
    }
    if (existing == null) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'SpannerId (${command.spannerId.value}) not found',
        ),
      );
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          deleteSpannerIds: <SpannerId>[command.spannerId],
        ),
        inverse: _MutationDelta(upsertSpanners: <NoteSpannerEntity>[existing]),
        affectedStartTick: const Tick(initialMapTick),
        affectedEndTick: const Tick(trailingRangeMarginTicks),
        affectsPlayback: false,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileUpsertTempoEvent(
    UpsertTempoEventCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final event = command.event;
    if (event.projectId != agg.project.projectId) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'TempoEvent projectId (${event.projectId.value}) does not match active project',
        ),
      );
    }
    if (event.tick.value < TempoTimelineCalculator.minTick ||
        event.usPerQuarter < minTempoUsPerQuarter) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid TempoEvent tick=${event.tick.value}, usPerQuarter=${event.usPerQuarter}',
        ),
      );
    }

    TempoEventEntity? priorById;
    TempoEventEntity? priorByTick;
    var zeroTickCount = 0;
    for (final existing in agg.tempoEvents) {
      if (existing.tick.value == initialMapTick) {
        zeroTickCount++;
      }
      if (existing.tempoEventId == event.tempoEventId) {
        priorById = existing;
      }
      if (existing.tick.value == event.tick.value) {
        priorByTick = existing;
      }
    }

    if (priorById != null &&
        priorById.tick.value == initialMapTick &&
        event.tick.value != initialMapTick &&
        zeroTickCount <= singleInitialEventCount) {
      return const Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.protectedInitialMapEvent,
          'Cannot move initial tick 0 tempo event away from tick 0',
        ),
      );
    }

    final deleteIds = <TempoEventId>[
      if (priorByTick != null &&
          priorByTick.tempoEventId != event.tempoEventId)
        priorByTick.tempoEventId,
    ];
    final restored = <TempoEventEntity>[
      ?priorById,
      if (priorByTick != null &&
          priorByTick.tempoEventId != priorById?.tempoEventId)
        priorByTick,
    ];
    final affectedStart = priorById != null
        ? math.min(priorById.tick.value, event.tick.value)
        : event.tick.value;

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          upsertTempoEvents: <TempoEventEntity>[event],
          deleteTempoEventIds: List<TempoEventId>.unmodifiable(deleteIds),
        ),
        inverse: _MutationDelta(
          upsertTempoEvents: List<TempoEventEntity>.unmodifiable(restored),
          deleteTempoEventIds: priorById == null
              ? <TempoEventId>[event.tempoEventId]
              : const <TempoEventId>[],
        ),
        affectedStartTick: Tick(affectedStart),
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: affectedStart,
        ),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileDeleteTempoEvent(
    DeleteTempoEventCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    TempoEventEntity? existing;
    for (final t in agg.tempoEvents) {
      if (t.tempoEventId == command.tempoEventId) {
        existing = t;
        break;
      }
    }
    if (existing == null) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'TempoEventId (${command.tempoEventId.value}) not found',
        ),
      );
    }
    if (existing.tick.value == initialMapTick) {
      return const Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.protectedInitialMapEvent,
          'Cannot delete initial tempo event at tick 0',
        ),
      );
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          deleteTempoEventIds: <TempoEventId>[command.tempoEventId],
        ),
        inverse: _MutationDelta(
          upsertTempoEvents: <TempoEventEntity>[existing],
        ),
        affectedStartTick: existing.tick,
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: existing.tick.value,
        ),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileUpsertTimeSignature(
    UpsertTimeSignatureCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final event = command.event;
    if (event.projectId != agg.project.projectId) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'TimeSignatureEvent projectId (${event.projectId.value}) does not match active project',
        ),
      );
    }
    if (event.tick.value < TempoTimelineCalculator.minTick ||
        event.numerator < TempoTimelineCalculator.minValidTimeSigNumerator ||
        !TempoTimelineCalculator.validTimeSigDenominators.contains(
          event.denominator,
        )) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid TimeSignatureEvent ${event.numerator}/${event.denominator} at tick ${event.tick.value}',
        ),
      );
    }

    TimeSignatureEventEntity? priorById;
    TimeSignatureEventEntity? priorByTick;
    var zeroTickCount = 0;
    for (final existing in agg.timeSignatureEvents) {
      if (existing.tick.value == initialMapTick) {
        zeroTickCount++;
      }
      if (existing.tsEventId == event.tsEventId) {
        priorById = existing;
      }
      if (existing.tick.value == event.tick.value) {
        priorByTick = existing;
      }
    }

    if (priorById != null &&
        priorById.tick.value == initialMapTick &&
        event.tick.value != initialMapTick &&
        zeroTickCount <= singleInitialEventCount) {
      return const Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.protectedInitialMapEvent,
          'Cannot move initial tick 0 time signature event away from tick 0',
        ),
      );
    }

    final deleteIds = <TimeSigEventId>[
      if (priorByTick != null && priorByTick.tsEventId != event.tsEventId)
        priorByTick.tsEventId,
    ];
    final restored = <TimeSignatureEventEntity>[
      ?priorById,
      if (priorByTick != null &&
          priorByTick.tsEventId != priorById?.tsEventId)
        priorByTick,
    ];
    final affectedStart = priorById != null
        ? math.min(priorById.tick.value, event.tick.value)
        : event.tick.value;

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          upsertTimeSignatureEvents: <TimeSignatureEventEntity>[event],
          deleteTimeSignatureEventIds: List<TimeSigEventId>.unmodifiable(
            deleteIds,
          ),
        ),
        inverse: _MutationDelta(
          upsertTimeSignatureEvents: List<TimeSignatureEventEntity>.unmodifiable(
            restored,
          ),
          deleteTimeSignatureEventIds: priorById == null
              ? <TimeSigEventId>[event.tsEventId]
              : const <TimeSigEventId>[],
        ),
        affectedStartTick: Tick(affectedStart),
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: affectedStart,
        ),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileDeleteTimeSignature(
    DeleteTimeSignatureCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    TimeSignatureEventEntity? existing;
    for (final ts in agg.timeSignatureEvents) {
      if (ts.tsEventId == command.tsEventId) {
        existing = ts;
        break;
      }
    }
    if (existing == null) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'TimeSigEventId (${command.tsEventId.value}) not found',
        ),
      );
    }
    if (existing.tick.value == initialMapTick) {
      return const Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.protectedInitialMapEvent,
          'Cannot delete initial time signature event at tick 0',
        ),
      );
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          deleteTimeSignatureEventIds: <TimeSigEventId>[command.tsEventId],
        ),
        inverse: _MutationDelta(
          upsertTimeSignatureEvents: <TimeSignatureEventEntity>[existing],
        ),
        affectedStartTick: existing.tick,
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: existing.tick.value,
        ),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileUpsertKeySignature(
    UpsertKeySignatureCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final event = command.event;
    if (event.projectId != agg.project.projectId) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'KeySignatureEvent projectId (${event.projectId.value}) does not match active project',
        ),
      );
    }
    if (event.tick.value < TempoTimelineCalculator.minTick ||
        event.fifths < minKeySigFifths ||
        event.fifths > maxKeySigFifths ||
        event.staffNumber < minKeySigStaffNumber ||
        event.staffNumber > maxKeySigStaffNumber) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid KeySignatureEvent at tick ${event.tick.value}: '
          'fifths=${event.fifths}, staff=${event.staffNumber}',
        ),
      );
    }
    if (event.partId != null) {
      final partsById = _indexPartsById(agg);
      final targetPart = partsById[event.partId];
      if (targetPart == null) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.entityNotFound,
            'KeySignatureEvent partId (${event.partId!.value}) not found',
          ),
        );
      }
      if (event.staffNumber > targetPart.stavesCount) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'KeySignature staffNumber (${event.staffNumber}) exceeds part '
            'stavesCount (${targetPart.stavesCount})',
          ),
        );
      }
    }

    KeySignatureEventEntity? priorById;
    KeySignatureEventEntity? priorBySlot;
    for (final existing in agg.keySignatureEvents) {
      if (existing.keyEventId == event.keyEventId) {
        priorById = existing;
      }
      final matchesSlot = event.partId == null
          ? existing.partId == null && existing.tick.value == event.tick.value
          : existing.partId == event.partId &&
                existing.staffNumber == event.staffNumber &&
                existing.tick.value == event.tick.value;
      if (matchesSlot) {
        priorBySlot = existing;
      }
    }

    final deleteIds = <KeySigEventId>[
      if (priorBySlot != null && priorBySlot.keyEventId != event.keyEventId)
        priorBySlot.keyEventId,
    ];
    final restored = <KeySignatureEventEntity>[
      ?priorById,
      if (priorBySlot != null && priorBySlot.keyEventId != priorById?.keyEventId)
        priorBySlot,
    ];

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          upsertKeySignatureEvents: <KeySignatureEventEntity>[event],
          deleteKeySignatureEventIds: List<KeySigEventId>.unmodifiable(
            deleteIds,
          ),
        ),
        inverse: _MutationDelta(
          upsertKeySignatureEvents: List<KeySignatureEventEntity>.unmodifiable(
            restored,
          ),
          deleteKeySignatureEventIds: priorById == null
              ? <KeySigEventId>[event.keyEventId]
              : const <KeySigEventId>[],
        ),
        affectedStartTick: event.tick,
        affectedEndTick: Tick(event.tick.value + trailingRangeMarginTicks),
        affectsPlayback: false,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileDeleteKeySignature(
    DeleteKeySignatureCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    KeySignatureEventEntity? existing;
    for (final ks in agg.keySignatureEvents) {
      if (ks.keyEventId == command.keyEventId) {
        existing = ks;
        break;
      }
    }
    if (existing == null) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'KeySigEventId (${command.keyEventId.value}) not found',
        ),
      );
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          deleteKeySignatureEventIds: <KeySigEventId>[command.keyEventId],
        ),
        inverse: _MutationDelta(
          upsertKeySignatureEvents: <KeySignatureEventEntity>[existing],
        ),
        affectedStartTick: existing.tick,
        affectedEndTick: Tick(existing.tick.value + trailingRangeMarginTicks),
        affectsPlayback: false,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileUpsertClefEvent(
    UpsertClefEventCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final event = command.event;
    final partsById = _indexPartsById(agg);
    final part = partsById[event.partId];
    final clefErr = _validateClef(event, agg.project.projectId, part);
    if (clefErr != null) {
      return Err<_UndoRedoEntry>(clefErr);
    }

    ClefEventEntity? priorById;
    ClefEventEntity? priorBySlot;
    for (final existing in agg.clefEvents) {
      if (existing.clefEventId == event.clefEventId) {
        priorById = existing;
      }
      if (existing.partId == event.partId &&
          existing.staffNumber == event.staffNumber &&
          existing.tick.value == event.tick.value) {
        priorBySlot = existing;
      }
    }

    final deleteIds = <ClefEventId>[
      if (priorBySlot != null && priorBySlot.clefEventId != event.clefEventId)
        priorBySlot.clefEventId,
    ];
    final restored = <ClefEventEntity>[
      ?priorById,
      if (priorBySlot != null &&
          priorBySlot.clefEventId != priorById?.clefEventId)
        priorBySlot,
    ];

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          upsertClefEvents: <ClefEventEntity>[event],
          deleteClefEventIds: List<ClefEventId>.unmodifiable(deleteIds),
        ),
        inverse: _MutationDelta(
          upsertClefEvents: List<ClefEventEntity>.unmodifiable(restored),
          deleteClefEventIds: priorById == null
              ? <ClefEventId>[event.clefEventId]
              : const <ClefEventId>[],
        ),
        affectedStartTick: event.tick,
        affectedEndTick: Tick(event.tick.value + trailingRangeMarginTicks),
        affectsPlayback: false,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileDeleteClefEvent(
    DeleteClefEventCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    ClefEventEntity? existing;
    for (final c in agg.clefEvents) {
      if (c.clefEventId == command.clefEventId) {
        existing = c;
        break;
      }
    }
    if (existing == null) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'ClefEventId (${command.clefEventId.value}) not found',
        ),
      );
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          deleteClefEventIds: <ClefEventId>[command.clefEventId],
        ),
        inverse: _MutationDelta(upsertClefEvents: <ClefEventEntity>[existing]),
        affectedStartTick: existing.tick,
        affectedEndTick: Tick(existing.tick.value + trailingRangeMarginTicks),
        affectsPlayback: false,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileAddProjectPart(
    AddProjectPartCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final part = command.part;
    if (part.projectId != agg.project.projectId) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Part projectId (${part.projectId.value}) does not match active project',
        ),
      );
    }

    final partBoundsErr = _validatePart(part);
    if (partBoundsErr != null) {
      return Err<_UndoRedoEntry>(partBoundsErr);
    }

    for (final existing in agg.parts) {
      if (existing.partId == part.partId) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.invalidMidiChannelOrPitch,
            'PartId (${part.partId.value}) already exists in project',
          ),
        );
      }
      if (existing.musicXmlPartId == part.musicXmlPartId) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.invalidMidiChannelOrPitch,
            'musicXmlPartId (${part.musicXmlPartId}) already exists in project',
          ),
        );
      }
    }

    final seenClefIds = <ClefEventId>{};
    final seenClefSlots = <(int, int)>{};
    for (final clef in command.initialClefs) {
      if (clef.partId != part.partId) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.entityNotFound,
            'Initial clef partId (${clef.partId.value}) must match new part '
            '(${part.partId.value})',
          ),
        );
      }
      final clefErr = _validateClef(clef, agg.project.projectId, part);
      if (clefErr != null) {
        return Err<_UndoRedoEntry>(clefErr);
      }
      if (!seenClefIds.add(clef.clefEventId) ||
          !seenClefSlots.add((clef.staffNumber, clef.tick.value))) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'Duplicate initial clef id or (staffNumber, tick) on part ${part.partId.value}',
          ),
        );
      }
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          upsertParts: <ProjectPartEntity>[part],
          upsertClefEvents: List<ClefEventEntity>.unmodifiable(
            command.initialClefs,
          ),
        ),
        inverse: _MutationDelta(deletePartIds: <PartId>[part.partId]),
        affectedStartTick: const Tick(initialMapTick),
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: initialMapTick,
        ),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileUpdatePartMixerOrPatch(
    UpdatePartMixerOrPatchCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final updated = command.updatedPart;
    if (updated.projectId != agg.project.projectId) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Updated part projectId (${updated.projectId.value}) does not match active project',
        ),
      );
    }

    ProjectPartEntity? existing;
    for (final part in agg.parts) {
      if (part.partId == updated.partId) {
        existing = part;
      } else if (part.musicXmlPartId == updated.musicXmlPartId) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.invalidMidiChannelOrPitch,
            'musicXmlPartId (${updated.musicXmlPartId}) conflicts with existing part '
            '(${part.partId.value})',
          ),
        );
      }
    }
    if (existing == null) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'PartId (${updated.partId.value}) not found',
        ),
      );
    }

    final partBoundsErr = _validatePart(updated);
    if (partBoundsErr != null) {
      return Err<_UndoRedoEntry>(partBoundsErr);
    }

    if (updated.stavesCount < existing.stavesCount) {
      final hasHigherStaffNote = agg.notes.any(
        (n) => n.partId == updated.partId && n.staffNumber > updated.stavesCount,
      );
      final hasHigherStaffClef = agg.clefEvents.any(
        (c) => c.partId == updated.partId && c.staffNumber > updated.stavesCount,
      );
      if (hasHigherStaffNote || hasHigherStaffClef) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'Cannot reduce stavesCount on part (${updated.partId.value}) while notes '
            'or clefs still reference staff > ${updated.stavesCount}',
          ),
        );
      }
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(upsertParts: <ProjectPartEntity>[updated]),
        inverse: _MutationDelta(upsertParts: <ProjectPartEntity>[existing]),
        affectedStartTick: const Tick(initialMapTick),
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: initialMapTick,
        ),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileReorderProjectParts(
    ReorderProjectPartsCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final orderedIds = command.orderedPartIds;
    if (orderedIds.length != agg.parts.length ||
        orderedIds.toSet().length != agg.parts.length) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'ReorderProjectPartsCommand must provide an exact permutation of '
          'all ${agg.parts.length} parts',
        ),
      );
    }

    final partsById = _indexPartsById(agg);
    final reordered = <ProjectPartEntity>[];
    final previous = List<ProjectPartEntity>.unmodifiable(agg.parts);
    final nowMs = DateTime.now().millisecondsSinceEpoch;

    for (var i = 0; i < orderedIds.length; i++) {
      final part = partsById[orderedIds[i]];
      if (part == null) {
        return Err<_UndoRedoEntry>(
          MuseError(
            MuseErrorCode.entityNotFound,
            'ReorderProjectPartsCommand contains unknown PartId (${orderedIds[i].value})',
          ),
        );
      }
      reordered.add(
        ProjectPartEntity(
          partId: part.partId,
          projectId: part.projectId,
          musicXmlPartId: part.musicXmlPartId,
          sortOrder: i,
          name: part.name,
          stavesCount: part.stavesCount,
          midiChannel: part.midiChannel,
          sfId: part.sfId,
          bankNum: part.bankNum,
          programNum: part.programNum,
          gainDb: part.gainDb,
          pan: part.pan,
          isMuted: part.isMuted,
          isSolo: part.isSolo,
          updatedAtMs: math.max(part.updatedAtMs, nowMs),
        ),
      );
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          upsertParts: List<ProjectPartEntity>.unmodifiable(reordered),
        ),
        inverse: _MutationDelta(upsertParts: previous),
        affectedStartTick: const Tick(initialMapTick),
        affectedEndTick: const Tick(trailingRangeMarginTicks),
        affectsPlayback: false,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileRemoveProjectPart(
    RemoveProjectPartCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final partsById = _indexPartsById(agg);
    final existingPart = partsById[command.partId];
    if (existingPart == null) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Cannot remove missing PartId (${command.partId.value})',
        ),
      );
    }

    final removedClefs = agg.clefEvents
        .where((c) => c.partId == command.partId)
        .toList(growable: false);
    final removedKeySigs = agg.keySignatureEvents
        .where((k) => k.partId == command.partId)
        .toList(growable: false);
    final removedNotes = agg.notes
        .where((n) => n.partId == command.partId)
        .toList(growable: false);
    final removedSpanners = agg.spanners
        .where((s) => s.partId == command.partId)
        .toList(growable: false);
    final removedTakes = agg.audioTakes
        .where((t) => t.partId == command.partId)
        .toList(growable: false);

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(deletePartIds: <PartId>[command.partId]),
        inverse: _MutationDelta(
          upsertParts: <ProjectPartEntity>[existingPart],
          upsertClefEvents: List<ClefEventEntity>.unmodifiable(removedClefs),
          upsertKeySignatureEvents: List<KeySignatureEventEntity>.unmodifiable(
            removedKeySigs,
          ),
          upsertNotes: List<TimelineNote>.unmodifiable(removedNotes),
          upsertSpanners: List<NoteSpannerEntity>.unmodifiable(removedSpanners),
          upsertAudioTakes: List<AudioTakeEntity>.unmodifiable(removedTakes),
        ),
        affectedStartTick: const Tick(initialMapTick),
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: initialMapTick,
        ),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileClearPartAudio(
    ClearPartAudioCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final partsById = _indexPartsById(agg);
    if (!partsById.containsKey(command.partId)) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Cannot clear audio for missing PartId (${command.partId.value})',
        ),
      );
    }

    final removedTakes = agg.audioTakes
        .where((t) => t.partId == command.partId)
        .toList(growable: false);
    var startTick = initialMapTick;
    if (removedTakes.isNotEmpty) {
      startTick = removedTakes
          .map((t) => t.startTick.value)
          .reduce(math.min);
    }

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(deleteAudioTakePartIds: <PartId>[command.partId]),
        inverse: _MutationDelta(
          upsertAudioTakes: List<AudioTakeEntity>.unmodifiable(removedTakes),
        ),
        affectedStartTick: Tick(startTick),
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: startTick,
        ),
        affectsPlayback: true,
      ),
    );
  }

  Result<_UndoRedoEntry> _compileUpdateProjectSettings(
    UpdateProjectSettingsCommand command,
    ProjectWorkspaceAggregate agg,
  ) {
    final trimmedTitle = command.title?.trim();
    if (trimmedTitle != null && trimmedTitle.isEmpty) {
      return const Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Project title cannot be empty',
        ),
      );
    }
    if (command.gridSnapTicks != null &&
        command.gridSnapTicks! < minDurationTicks) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'gridSnapTicks (${command.gridSnapTicks}) must be >= $minDurationTicks',
        ),
      );
    }
    if (command.pickupTicks != null &&
        command.pickupTicks! < TempoTimelineCalculator.minTick) {
      return Err<_UndoRedoEntry>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'pickupTicks (${command.pickupTicks}) must be >= ${TempoTimelineCalculator.minTick}',
        ),
      );
    }

    final proj = agg.project;
    final timingModeChanged =
        command.playbackTimingMode != null &&
        command.playbackTimingMode != proj.playbackTimingMode;
    final pickupChanged =
        command.pickupTicks != null && command.pickupTicks != proj.pickupTicks;

    return Ok<_UndoRedoEntry>(
      _UndoRedoEntry(
        forward: _MutationDelta(
          metadataPatch: _MetadataPatch(
            title: trimmedTitle,
            gridSnapTicks: command.gridSnapTicks,
            pickupTicks: command.pickupTicks,
            playbackTimingMode: command.playbackTimingMode,
          ),
        ),
        inverse: _MutationDelta(
          metadataPatch: _MetadataPatch(
            title: proj.title,
            gridSnapTicks: proj.gridSnapTicks,
            pickupTicks: proj.pickupTicks,
            playbackTimingMode: proj.playbackTimingMode,
          ),
        ),
        affectedStartTick: const Tick(initialMapTick),
        affectedEndTick: _computeMaxAffectedEndTick(
          agg,
          minimumStartTick: initialMapTick,
        ),
        affectsPlayback: timingModeChanged || pickupChanged,
      ),
    );
  }

  MuseError? _validateNote(
    TimelineNote note,
    ProjectId expectedProjectId,
    Map<PartId, ProjectPartEntity> partsById,
  ) {
    if (note.projectId != expectedProjectId) {
      return MuseError(
        MuseErrorCode.entityNotFound,
        'Note projectId (${note.projectId.value}) does not match active project',
      );
    }
    final part = partsById[note.partId];
    if (part == null) {
      return MuseError(
        MuseErrorCode.entityNotFound,
        'Note partId (${note.partId.value}) not found',
      );
    }
    if (note.pitchMidi < MuseConstants.minMidiPitch ||
        note.pitchMidi > MuseConstants.maxMidiPitch ||
        note.velocity < MuseConstants.minMidiVelocity ||
        note.velocity > MuseConstants.maxMidiVelocity) {
      return MuseError(
        MuseErrorCode.invalidMidiChannelOrPitch,
        'Note (${note.noteId.value}) pitchMidi=${note.pitchMidi} or '
        'velocity=${note.velocity} out of MIDI bounds',
      );
    }
    if (note.staffNumber < minStaffNumber ||
        note.staffNumber > part.stavesCount ||
        note.voiceNumber < minVoiceNumber ||
        note.voiceNumber > maxVoiceNumber ||
        note.rawStartTick.value < TempoTimelineCalculator.minTick ||
        note.quantizedStartTick.value < TempoTimelineCalculator.minTick ||
        note.rawDurationTicks < minDurationTicks ||
        note.quantizedDurationTicks < minDurationTicks ||
        note.enharmonicAlter < minEnharmonicAlter ||
        note.enharmonicAlter > maxEnharmonicAlter) {
      return MuseError(
        MuseErrorCode.invalidTickRange,
        'Note (${note.noteId.value}) has out-of-range staff, voice, tick, '
        'duration, or enharmonicAlter',
      );
    }
    return null;
  }

  MuseError? _validateClef(
    ClefEventEntity clef,
    ProjectId expectedProjectId,
    ProjectPartEntity? part,
  ) {
    if (clef.projectId != expectedProjectId) {
      return MuseError(
        MuseErrorCode.entityNotFound,
        'Clef projectId (${clef.projectId.value}) does not match active project',
      );
    }
    if (part == null) {
      return MuseError(
        MuseErrorCode.entityNotFound,
        'Clef partId (${clef.partId.value}) not found',
      );
    }
    if (clef.staffNumber < minStaffNumber ||
        clef.staffNumber > part.stavesCount ||
        clef.tick.value < TempoTimelineCalculator.minTick ||
        clef.line < minClefLine ||
        clef.line > maxClefLine ||
        clef.octaveChange < minClefOctaveChange ||
        clef.octaveChange > maxClefOctaveChange) {
      return MuseError(
        MuseErrorCode.invalidTickRange,
        'Invalid ClefEvent staff=${clef.staffNumber}, tick=${clef.tick.value}, '
        'line=${clef.line}, octaveChange=${clef.octaveChange}',
      );
    }
    return null;
  }

  MuseError? _validatePart(ProjectPartEntity part) {
    if (part.name.trim().length < minNonEmptyLength ||
        part.musicXmlPartId.trim().length < minNonEmptyLength ||
        part.stavesCount < minStavesCount ||
        part.stavesCount > maxStavesCount ||
        part.sortOrder < minSortOrder) {
      return MuseError(
        MuseErrorCode.invalidTickRange,
        'Invalid part metadata for ${part.partId.value}',
      );
    }
    if (part.midiChannel < MuseConstants.minMidiChannel ||
        part.midiChannel > MuseConstants.maxMidiChannel ||
        part.bankNum < MuseConstants.minBankNum ||
        part.bankNum > MuseConstants.maxBankNum ||
        part.programNum < MuseConstants.minProgramNum ||
        part.programNum > MuseConstants.maxProgramNum ||
        !part.pan.isFinite ||
        part.pan < minPan ||
        part.pan > maxPan ||
        !part.gainDb.isFinite) {
      return MuseError(
        MuseErrorCode.invalidMidiChannelOrPitch,
        'Invalid MIDI channel, bank, program, gain, or pan on part ${part.partId.value}',
      );
    }
    return null;
  }

  static Map<PartId, ProjectPartEntity> _indexPartsById(
    ProjectWorkspaceAggregate agg,
  ) => <PartId, ProjectPartEntity>{for (final p in agg.parts) p.partId: p};

  static Map<NoteId, TimelineNote> _indexNotesById(
    ProjectWorkspaceAggregate agg,
  ) => <NoteId, TimelineNote>{for (final n in agg.notes) n.noteId: n};

  static (int, int) _expandSpanForNote(
    TimelineNote note,
    int currentMinStart,
    int currentMaxEnd,
  ) {
    final nextMin = math.min(
      currentMinStart,
      math.min(note.rawStartTick.value, note.quantizedStartTick.value),
    );
    final nextMax = math.max(
      currentMaxEnd,
      math.max(
        note.rawStartTick.value + note.rawDurationTicks,
        note.quantizedStartTick.value + note.quantizedDurationTicks,
      ),
    );
    return (nextMin, nextMax);
  }

  static Tick _computeMaxAffectedEndTick(
    ProjectWorkspaceAggregate agg, {
    required int minimumStartTick,
  }) {
    var maxTick = minimumStartTick + trailingRangeMarginTicks;
    for (final note in agg.notes) {
      maxTick = math.max(
        maxTick,
        math.max(
          note.rawStartTick.value + note.rawDurationTicks,
          note.quantizedStartTick.value + note.quantizedDurationTicks,
        ),
      );
    }
    for (final tempo in agg.tempoEvents) {
      maxTick = math.max(maxTick, tempo.tick.value + trailingRangeMarginTicks);
    }
    for (final ts in agg.timeSignatureEvents) {
      maxTick = math.max(maxTick, ts.tick.value + trailingRangeMarginTicks);
    }
    if (agg.audioTakes.isNotEmpty) {
      final calculator = TempoTimelineCalculator(
        tempoEvents: agg.tempoEvents,
        timeSignatureEvents: agg.timeSignatureEvents,
        pickupTicks: agg.project.pickupTicks,
      );
      for (final take in agg.audioTakes) {
        final startFrame = calculator.tickToSampleFrame(
          take.startTick,
          sampleRate: take.sampleRate,
        );
        final endTick = calculator.sampleFrameToTick(
          SampleFrame(startFrame.value + take.durationFrames),
          sampleRate: take.sampleRate,
        );
        maxTick = math.max(maxTick, endTick.value + trailingRangeMarginTicks);
      }
    }
    return Tick(maxTick);
  }
}
