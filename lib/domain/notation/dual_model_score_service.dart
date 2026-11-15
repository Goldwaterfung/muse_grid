/// Pure Dart dual-model score synchronization (`960 PPQN` <-> `StaffSystem`)
/// with an GC-friendly `Expando` $O(\log N + K)$ Piano Roll spatial index.
library;

import 'dart:math' as math;

import 'package:crisp_notation_core/crisp_notation_core.dart' show StaffSystem;

import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../models/score_models.dart';
import '../timeline/tempo_timeline_calculator.dart';
import 'crisp_score_mapper.dart';

/// Deterministic engraved `crisp_notation_core` snapshot paired with project revision.
final class ScoreRenderSnapshot {
  final StaffSystem crispScoreModel;
  final int revision;

  const ScoreRenderSnapshot({
    required this.crispScoreModel,
    required this.revision,
  });
}

/// Synchronized immutable workspace snapshot pairing SQLite aggregate + engraved AST.
final class ScoreWorkspaceState {
  final ProjectWorkspaceAggregate aggregate;
  final ScoreRenderSnapshot renderSnapshot;

  const ScoreWorkspaceState({
    required this.aggregate,
    required this.renderSnapshot,
  });
}

/// Pure Dart contract for dual-model engraving, MusicXML I/O, and viewport culling.
abstract interface class IDualModelScoreService {
  Result<ScoreWorkspaceState> buildWorkspaceState(
    ProjectWorkspaceAggregate aggregate,
  );

  Result<ProjectWorkspaceAggregate> importFromMusicXmlBytes({
    required List<int> bytes,
    required bool isCompressedMxl,
    required String fallbackTitle,
    SoundFontId? defaultSoundFontId,
  });

  Result<List<int>> exportToMusicXmlBytes({
    required ProjectWorkspaceAggregate aggregate,
    required bool compressAsMxl,
  });

  Result<ScoreWorkspaceState> applyMutationToDualModel(
    ScoreWorkspaceState currentState,
    ScoreMutationBatch mutation,
  );

  List<TimelineNote> queryNotesInViewport({
    required ScoreWorkspaceState state,
    required PartId partId,
    required Tick startTick,
    required Tick endTick,
    required int minPitchMidi,
    required int maxPitchMidi,
    required PlaybackTimingMode timingMode,
  });
}

final class _TimingModeSpatialIndex {
  final List<TimelineNote> notes;
  final List<int> startTicks;
  final List<int> prefixMaxEndTick;
  final List<int> maxEndTree;
  final int treeCapacity;

  const _TimingModeSpatialIndex._({
    required this.notes,
    required this.startTicks,
    required this.prefixMaxEndTick,
    required this.maxEndTree,
    required this.treeCapacity,
  });

  static const _TimingModeSpatialIndex empty = _TimingModeSpatialIndex._(
    notes: <TimelineNote>[],
    startTicks: <int>[],
    prefixMaxEndTick: <int>[],
    maxEndTree: <int>[],
    treeCapacity: 0,
  );

  static const int _rootNode = 1;
  static const int _minValidEndSentinel = 0;

  factory _TimingModeSpatialIndex.build(
    List<TimelineNote> partNotes,
    PlaybackTimingMode mode,
  ) {
    if (partNotes.isEmpty) {
      return empty;
    }

    int startOf(TimelineNote n) => mode == PlaybackTimingMode.raw
        ? n.rawStartTick.value
        : n.quantizedStartTick.value;

    int durationOf(TimelineNote n) => mode == PlaybackTimingMode.raw
        ? n.rawDurationTicks
        : n.quantizedDurationTicks;

    final sorted = List<TimelineNote>.from(partNotes)
      ..sort((a, b) {
        final byStart = startOf(a).compareTo(startOf(b));
        if (byStart != 0) return byStart;
        final byPitch = a.pitchMidi.compareTo(b.pitchMidi);
        if (byPitch != 0) return byPitch;
        return a.noteId.value.compareTo(b.noteId.value);
      });

    final count = sorted.length;
    final startTicks = List<int>.filled(count, 0);
    final prefixMaxEndTick = List<int>.filled(count, 0);
    var runningMaxEnd = _minValidEndSentinel;

    var capacity = 1;
    while (capacity < count) {
      capacity <<= 1;
    }
    final maxEndTree = List<int>.filled(capacity * 2, _minValidEndSentinel);

    for (var i = 0; i < count; i++) {
      final note = sorted[i];
      final s = startOf(note);
      final e = s + durationOf(note);
      startTicks[i] = s;
      if (e > runningMaxEnd) {
        runningMaxEnd = e;
      }
      prefixMaxEndTick[i] = runningMaxEnd;
      maxEndTree[capacity + i] = e;
    }

    for (var node = capacity - 1; node >= _rootNode; node--) {
      final left = maxEndTree[node << 1];
      final right = maxEndTree[(node << 1) | 1];
      maxEndTree[node] = left >= right ? left : right;
    }

    return _TimingModeSpatialIndex._(
      notes: List<TimelineNote>.unmodifiable(sorted),
      startTicks: startTicks,
      prefixMaxEndTick: prefixMaxEndTick,
      maxEndTree: maxEndTree,
      treeCapacity: capacity,
    );
  }

  List<TimelineNote> query({
    required int startTick,
    required int endTick,
    required int minPitchMidi,
    required int maxPitchMidi,
  }) {
    if (notes.isEmpty || endTick < startTick || minPitchMidi > maxPitchMidi) {
      return const <TimelineNote>[];
    }

    // Upper bound for note.startTick <= endTick.
    final rightExclusive = _upperBound(startTicks, endTick);
    if (rightExclusive == 0 ||
        prefixMaxEndTick[rightExclusive - 1] <= startTick) {
      return const <TimelineNote>[];
    }

    final results = <TimelineNote>[];
    _collectIntersecting(
      node: _rootNode,
      nodeLeft: 0,
      nodeRight: treeCapacity - 1,
      rightExclusive: rightExclusive,
      startTick: startTick,
      minPitchMidi: minPitchMidi,
      maxPitchMidi: maxPitchMidi,
      out: results,
    );
    return List<TimelineNote>.unmodifiable(results);
  }

  void _collectIntersecting({
    required int node,
    required int nodeLeft,
    required int nodeRight,
    required int rightExclusive,
    required int startTick,
    required int minPitchMidi,
    required int maxPitchMidi,
    required List<TimelineNote> out,
  }) {
    if (nodeLeft >= rightExclusive || maxEndTree[node] <= startTick) {
      return;
    }
    if (nodeLeft == nodeRight) {
      final note = notes[nodeLeft];
      if (note.pitchMidi >= minPitchMidi && note.pitchMidi <= maxPitchMidi) {
        out.add(note);
      }
      return;
    }
    final mid = (nodeLeft + nodeRight) >> 1;
    _collectIntersecting(
      node: node << 1,
      nodeLeft: nodeLeft,
      nodeRight: mid,
      rightExclusive: rightExclusive,
      startTick: startTick,
      minPitchMidi: minPitchMidi,
      maxPitchMidi: maxPitchMidi,
      out: out,
    );
    _collectIntersecting(
      node: (node << 1) | 1,
      nodeLeft: mid + 1,
      nodeRight: nodeRight,
      rightExclusive: rightExclusive,
      startTick: startTick,
      minPitchMidi: minPitchMidi,
      maxPitchMidi: maxPitchMidi,
      out: out,
    );
  }

  static int _upperBound(List<int> sorted, int target) {
    var low = 0;
    var high = sorted.length;
    while (low < high) {
      final mid = (low + high) >>> 1;
      if (sorted[mid] <= target) {
        low = mid + 1;
      } else {
        high = mid;
      }
    }
    return low;
  }
}

final class _PartSpatialIndexes {
  final _TimingModeSpatialIndex quantized;
  final _TimingModeSpatialIndex raw;

  const _PartSpatialIndexes({required this.quantized, required this.raw});

  _TimingModeSpatialIndex forMode(PlaybackTimingMode mode) =>
      mode == PlaybackTimingMode.raw ? raw : quantized;
}

final class _ProjectSpatialIndex {
  final Map<PartId, _PartSpatialIndexes> byPart;

  const _ProjectSpatialIndex(this.byPart);

  factory _ProjectSpatialIndex.build(ProjectWorkspaceAggregate aggregate) {
    final grouped = <PartId, List<TimelineNote>>{};
    for (final part in aggregate.parts) {
      grouped[part.partId] = <TimelineNote>[];
    }
    for (final note in aggregate.notes) {
      grouped.putIfAbsent(note.partId, () => <TimelineNote>[]).add(note);
    }
    final byPart = <PartId, _PartSpatialIndexes>{
      for (final entry in grouped.entries)
        entry.key: _PartSpatialIndexes(
          quantized: _TimingModeSpatialIndex.build(
            entry.value,
            PlaybackTimingMode.quantized,
          ),
          raw: _TimingModeSpatialIndex.build(
            entry.value,
            PlaybackTimingMode.raw,
          ),
        ),
    };
    return _ProjectSpatialIndex(byPart);
  }
}

/// Synchronized Pure Dart manager for MuseGrid `960 PPQN` models and `StaffSystem` ASTs.
final class DualModelScoreService implements IDualModelScoreService {
  static const int _revisionStep = 1;
  static const int _initialMapTick = 0;

  final CrispScoreMapper _mapper;
  final Expando<_ProjectSpatialIndex> _spatialIndexes =
      Expando<_ProjectSpatialIndex>('MuseGridSpatialIndex');

  DualModelScoreService({this._mapper = const CrispScoreMapper()});

  @override
  Result<ScoreWorkspaceState> buildWorkspaceState(
    ProjectWorkspaceAggregate aggregate,
  ) {
    final validationError = _validateTimelineMaps(
      tempoEvents: aggregate.tempoEvents,
      timeSignatureEvents: aggregate.timeSignatureEvents,
      pickupTicks: aggregate.project.pickupTicks,
    );
    if (validationError != null) {
      return Err<ScoreWorkspaceState>(validationError);
    }

    try {
      final calculator = TempoTimelineCalculator(
        tempoEvents: aggregate.tempoEvents,
        timeSignatureEvents: aggregate.timeSignatureEvents,
        pickupTicks: aggregate.project.pickupTicks,
      );
      final staffSystem = _mapper.aggregateToStaffSystem(
        aggregate,
        timelineCalculator: calculator,
      );
      final state = ScoreWorkspaceState(
        aggregate: aggregate,
        renderSnapshot: ScoreRenderSnapshot(
          crispScoreModel: staffSystem,
          revision: aggregate.project.revision,
        ),
      );
      _spatialIndexes[state] = _ProjectSpatialIndex.build(aggregate);
      return Ok<ScoreWorkspaceState>(state);
    } on ArgumentError catch (e) {
      return Err<ScoreWorkspaceState>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid score timeline parameters',
          cause: e,
        ),
      );
    }
  }

  @override
  Result<ProjectWorkspaceAggregate> importFromMusicXmlBytes({
    required List<int> bytes,
    required bool isCompressedMxl,
    required String fallbackTitle,
    SoundFontId? defaultSoundFontId,
  }) {
    return _mapper.importFromMusicXmlBytes(
      bytes: bytes,
      isCompressedMxl: isCompressedMxl,
      fallbackTitle: fallbackTitle,
      defaultSoundFontId: defaultSoundFontId,
    );
  }

  @override
  Result<List<int>> exportToMusicXmlBytes({
    required ProjectWorkspaceAggregate aggregate,
    required bool compressAsMxl,
  }) {
    return _mapper.exportToMusicXmlBytes(
      aggregate: aggregate,
      compressAsMxl: compressAsMxl,
    );
  }

  @override
  Result<ScoreWorkspaceState> applyMutationToDualModel(
    ScoreWorkspaceState currentState,
    ScoreMutationBatch mutation,
  ) {
    final currentAgg = currentState.aggregate;
    if (mutation.projectId != currentAgg.project.projectId) {
      return Err<ScoreWorkspaceState>(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Mutation projectId (${mutation.projectId.value}) does not match '
          'current project (${currentAgg.project.projectId.value})',
        ),
      );
    }
    if (mutation.expectedRevision != currentAgg.project.revision) {
      return Err<ScoreWorkspaceState>(
        MuseError(
          MuseErrorCode.revisionConflict,
          'Expected revision ${mutation.expectedRevision} does not match '
          'current revision ${currentAgg.project.revision}',
        ),
      );
    }

    final metaUpdate = mutation.projectMetadataUpdate;
    if (metaUpdate != null) {
      if (metaUpdate.projectId != currentAgg.project.projectId) {
        return Err<ScoreWorkspaceState>(
          MuseError(
            MuseErrorCode.entityNotFound,
            'Metadata update projectId (${metaUpdate.projectId.value}) '
            'does not match current project',
          ),
        );
      }
      if (metaUpdate.expectedRevision != currentAgg.project.revision) {
        return Err<ScoreWorkspaceState>(
          MuseError(
            MuseErrorCode.revisionConflict,
            'Metadata expectedRevision ${metaUpdate.expectedRevision} does not '
            'match current revision ${currentAgg.project.revision}',
          ),
        );
      }
      if (metaUpdate.title != null && metaUpdate.title!.trim().isEmpty) {
        return const Err<ScoreWorkspaceState>(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'Project title cannot be empty',
          ),
        );
      }
      if (metaUpdate.gridSnapTicks != null && metaUpdate.gridSnapTicks! <= 0) {
        return Err<ScoreWorkspaceState>(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'gridSnapTicks (${metaUpdate.gridSnapTicks}) must be > 0',
          ),
        );
      }
      if (metaUpdate.pickupTicks != null &&
          metaUpdate.pickupTicks! < TempoTimelineCalculator.minTick) {
        return Err<ScoreWorkspaceState>(
          MuseError(
            MuseErrorCode.invalidTickRange,
            'pickupTicks (${metaUpdate.pickupTicks}) must be >= 0',
          ),
        );
      }
    }

    final nowMs = DateTime.now().millisecondsSinceEpoch;
    final nextRevision = currentAgg.project.revision + _revisionStep;
    final nextProject = ProjectSummary(
      projectId: currentAgg.project.projectId,
      title: metaUpdate?.title?.trim() ?? currentAgg.project.title,
      ppqn: currentAgg.project.ppqn,
      gridSnapTicks:
          metaUpdate?.gridSnapTicks ?? currentAgg.project.gridSnapTicks,
      pickupTicks: metaUpdate?.pickupTicks ?? currentAgg.project.pickupTicks,
      playbackTimingMode:
          metaUpdate?.playbackTimingMode ??
          currentAgg.project.playbackTimingMode,
      revision: nextRevision,
      createdAtMs: currentAgg.project.createdAtMs,
      updatedAtMs: math.max(currentAgg.project.updatedAtMs, nowMs),
    );

    final deletedPartIds = mutation.deletePartIds.toSet();
    final affectedPartIds = <PartId>{};

    // Parts
    final partMap = <PartId, ProjectPartEntity>{
      for (final p in currentAgg.parts)
        if (!deletedPartIds.contains(p.partId)) p.partId: p,
    };
    for (final p in mutation.upsertParts) {
      partMap[p.partId] = p;
    }

    // Tempo Events
    final deletedTempoIds = mutation.deleteTempoEventIds.toSet();
    final tempoMap = <TempoEventId, TempoEventEntity>{
      for (final t in currentAgg.tempoEvents)
        if (!deletedTempoIds.contains(t.tempoEventId)) t.tempoEventId: t,
    };
    for (final t in mutation.upsertTempoEvents) {
      tempoMap[t.tempoEventId] = t;
    }

    // Time Signature Events
    final deletedTimeSigIds = mutation.deleteTimeSignatureEventIds.toSet();
    final timeSigMap = <TimeSigEventId, TimeSignatureEventEntity>{
      for (final ts in currentAgg.timeSignatureEvents)
        if (!deletedTimeSigIds.contains(ts.tsEventId)) ts.tsEventId: ts,
    };
    for (final ts in mutation.upsertTimeSignatureEvents) {
      timeSigMap[ts.tsEventId] = ts;
    }

    // Key Signature Events (with part cascade and global tracking)
    final deletedKeySigIds = mutation.deleteKeySignatureEventIds.toSet();
    var globalKeyChanged = false;
    final keySigMap = <KeySigEventId, KeySignatureEventEntity>{};
    for (final ks in currentAgg.keySignatureEvents) {
      final removedById = deletedKeySigIds.contains(ks.keyEventId);
      final removedByPart =
          ks.partId != null && deletedPartIds.contains(ks.partId);
      if (removedById || removedByPart) {
        if (ks.partId == null) {
          globalKeyChanged = true;
        } else if (!deletedPartIds.contains(ks.partId)) {
          affectedPartIds.add(ks.partId!);
        }
        continue;
      }
      keySigMap[ks.keyEventId] = ks;
    }
    for (final ks in mutation.upsertKeySignatureEvents) {
      final prior = keySigMap[ks.keyEventId];
      if (prior != null && prior.partId != ks.partId) {
        if (prior.partId == null) {
          globalKeyChanged = true;
        } else if (!deletedPartIds.contains(prior.partId)) {
          affectedPartIds.add(prior.partId!);
        }
      }
      keySigMap[ks.keyEventId] = ks;
      if (ks.partId == null) {
        globalKeyChanged = true;
      } else {
        affectedPartIds.add(ks.partId!);
      }
    }

    // Clef Events (with part cascade)
    final deletedClefIds = mutation.deleteClefEventIds.toSet();
    final clefMap = <ClefEventId, ClefEventEntity>{};
    for (final c in currentAgg.clefEvents) {
      if (deletedClefIds.contains(c.clefEventId) ||
          deletedPartIds.contains(c.partId)) {
        if (!deletedPartIds.contains(c.partId)) {
          affectedPartIds.add(c.partId);
        }
        continue;
      }
      clefMap[c.clefEventId] = c;
    }
    for (final c in mutation.upsertClefEvents) {
      final prior = clefMap[c.clefEventId];
      if (prior != null &&
          prior.partId != c.partId &&
          !deletedPartIds.contains(prior.partId)) {
        affectedPartIds.add(prior.partId);
      }
      clefMap[c.clefEventId] = c;
      affectedPartIds.add(c.partId);
    }

    // Notes (with part cascade)
    final deletedNoteIds = mutation.deleteNoteIds.toSet();
    final cascadedDeletedNoteIds = <NoteId>{...deletedNoteIds};
    final noteMap = <NoteId, TimelineNote>{};
    for (final n in currentAgg.notes) {
      if (deletedNoteIds.contains(n.noteId) ||
          deletedPartIds.contains(n.partId)) {
        cascadedDeletedNoteIds.add(n.noteId);
        if (!deletedPartIds.contains(n.partId)) {
          affectedPartIds.add(n.partId);
        }
        continue;
      }
      noteMap[n.noteId] = n;
    }
    for (final n in mutation.upsertNotes) {
      final prior = noteMap[n.noteId];
      if (prior != null &&
          prior.partId != n.partId &&
          !deletedPartIds.contains(prior.partId)) {
        affectedPartIds.add(prior.partId);
      }
      noteMap[n.noteId] = n;
      affectedPartIds.add(n.partId);
    }

    // Spanners (with part and note cascade)
    final deletedSpannerIds = mutation.deleteSpannerIds.toSet();
    final priorSpannerParts = <SpannerId, PartId>{
      for (final s in currentAgg.spanners) s.spannerId: s.partId,
    };
    final spannerMap = <SpannerId, NoteSpannerEntity>{};
    for (final s in currentAgg.spanners) {
      final startNote = noteMap[s.startNoteId];
      final endNote = noteMap[s.endNoteId];
      final mismatchedEndpointPart =
          startNote == null ||
          endNote == null ||
          startNote.partId != s.partId ||
          endNote.partId != s.partId;
      final removed =
          deletedSpannerIds.contains(s.spannerId) ||
          deletedPartIds.contains(s.partId) ||
          cascadedDeletedNoteIds.contains(s.startNoteId) ||
          cascadedDeletedNoteIds.contains(s.endNoteId) ||
          mismatchedEndpointPart;
      if (removed) {
        if (!deletedPartIds.contains(s.partId)) {
          affectedPartIds.add(s.partId);
        }
        continue;
      }
      spannerMap[s.spannerId] = s;
    }
    for (final s in mutation.upsertSpanners) {
      final priorPart = priorSpannerParts[s.spannerId];
      if (priorPart != null &&
          priorPart != s.partId &&
          !deletedPartIds.contains(priorPart)) {
        affectedPartIds.add(priorPart);
      }
      spannerMap[s.spannerId] = s;
      affectedPartIds.add(s.partId);
    }

    // Audio Takes (with part cascade and UNIQUE(project_id, part_id) overwrite)
    final deletedTakePartIds = mutation.deleteAudioTakePartIds.toSet();
    final takeByPart = <PartId, AudioTakeEntity>{};
    for (final take in currentAgg.audioTakes) {
      if (!deletedPartIds.contains(take.partId) &&
          !deletedTakePartIds.contains(take.partId)) {
        takeByPart[take.partId] = take;
      }
    }
    for (final take in mutation.upsertAudioTakes) {
      takeByPart[take.partId] = take;
    }

    final nextTempos = List<TempoEventEntity>.unmodifiable(tempoMap.values);
    final nextTimeSigs = List<TimeSignatureEventEntity>.unmodifiable(
      timeSigMap.values,
    );

    final mapValidationError = _validateTimelineMaps(
      tempoEvents: nextTempos,
      timeSignatureEvents: nextTimeSigs,
      pickupTicks: nextProject.pickupTicks,
    );
    if (mapValidationError != null) {
      return Err<ScoreWorkspaceState>(mapValidationError);
    }

    final sortedParts = partMap.values.toList(growable: false)
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.partId.value.compareTo(b.partId.value);
      });

    final nextAggregate = ProjectWorkspaceAggregate(
      project: nextProject,
      parts: List<ProjectPartEntity>.unmodifiable(sortedParts),
      tempoEvents: nextTempos,
      timeSignatureEvents: nextTimeSigs,
      keySignatureEvents: List<KeySignatureEventEntity>.unmodifiable(
        keySigMap.values,
      ),
      clefEvents: List<ClefEventEntity>.unmodifiable(clefMap.values),
      notes: List<TimelineNote>.unmodifiable(noteMap.values),
      spanners: List<NoteSpannerEntity>.unmodifiable(spannerMap.values),
      audioTakes: List<AudioTakeEntity>.unmodifiable(takeByPart.values),
    );

    final TempoTimelineCalculator calculator;
    try {
      calculator = TempoTimelineCalculator(
        tempoEvents: nextAggregate.tempoEvents,
        timeSignatureEvents: nextAggregate.timeSignatureEvents,
        pickupTicks: nextAggregate.project.pickupTicks,
      );
    } on ArgumentError catch (e) {
      return Err<ScoreWorkspaceState>(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid timeline map after mutation',
          cause: e,
        ),
      );
    }

    final hasGlobalChange =
        (metaUpdate?.title != null &&
            metaUpdate!.title!.trim() != currentAgg.project.title) ||
        (metaUpdate?.pickupTicks != null &&
            metaUpdate!.pickupTicks != currentAgg.project.pickupTicks) ||
        mutation.upsertParts.isNotEmpty ||
        mutation.deletePartIds.isNotEmpty ||
        mutation.upsertTempoEvents.isNotEmpty ||
        mutation.deleteTempoEventIds.isNotEmpty ||
        mutation.upsertTimeSignatureEvents.isNotEmpty ||
        mutation.deleteTimeSignatureEventIds.isNotEmpty ||
        globalKeyChanged;

    final StaffSystem nextStaffSystem = hasGlobalChange
        ? _mapper.aggregateToStaffSystem(
            nextAggregate,
            timelineCalculator: calculator,
          )
        : _mapper.rebuildAffectedStaves(
            nextAggregate: nextAggregate,
            previousSystem: currentState.renderSnapshot.crispScoreModel,
            affectedPartIds: affectedPartIds,
            timelineCalculator: calculator,
          );

    final nextState = ScoreWorkspaceState(
      aggregate: nextAggregate,
      renderSnapshot: ScoreRenderSnapshot(
        crispScoreModel: nextStaffSystem,
        revision: nextRevision,
      ),
    );
    _spatialIndexes[nextState] = _ProjectSpatialIndex.build(nextAggregate);
    return Ok<ScoreWorkspaceState>(nextState);
  }

  @override
  List<TimelineNote> queryNotesInViewport({
    required ScoreWorkspaceState state,
    required PartId partId,
    required Tick startTick,
    required Tick endTick,
    required int minPitchMidi,
    required int maxPitchMidi,
    required PlaybackTimingMode timingMode,
  }) {
    if (endTick.value < startTick.value || minPitchMidi > maxPitchMidi) {
      return const <TimelineNote>[];
    }

    var index = _spatialIndexes[state];
    if (index == null) {
      index = _ProjectSpatialIndex.build(state.aggregate);
      _spatialIndexes[state] = index;
    }

    final partIndex = index.byPart[partId];
    if (partIndex == null) {
      return const <TimelineNote>[];
    }

    return partIndex
        .forMode(timingMode)
        .query(
          startTick: startTick.value,
          endTick: endTick.value,
          minPitchMidi: minPitchMidi,
          maxPitchMidi: maxPitchMidi,
        );
  }

  static MuseError? _validateTimelineMaps({
    required List<TempoEventEntity> tempoEvents,
    required List<TimeSignatureEventEntity> timeSignatureEvents,
    required int pickupTicks,
  }) {
    if (pickupTicks < TempoTimelineCalculator.minTick) {
      return MuseError(
        MuseErrorCode.invalidTickRange,
        'pickupTicks ($pickupTicks) must be >= ${TempoTimelineCalculator.minTick}',
      );
    }

    final hasInitialTempo = tempoEvents.any(
      (e) => e.tick.value == _initialMapTick,
    );
    if (!hasInitialTempo) {
      return const MuseError(
        MuseErrorCode.protectedInitialMapEvent,
        'Project must retain a tempo event at tick 0',
      );
    }

    final hasInitialTimeSig = timeSignatureEvents.any(
      (e) => e.tick.value == _initialMapTick,
    );
    if (!hasInitialTimeSig) {
      return const MuseError(
        MuseErrorCode.protectedInitialMapEvent,
        'Project must retain a time signature event at tick 0',
      );
    }

    for (final ts in timeSignatureEvents) {
      if (ts.numerator < TempoTimelineCalculator.minValidTimeSigNumerator ||
          !TempoTimelineCalculator.validTimeSigDenominators.contains(
            ts.denominator,
          )) {
        return MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid time signature ${ts.numerator}/${ts.denominator}',
        );
      }
    }

    for (final t in tempoEvents) {
      if (t.tick.value < TempoTimelineCalculator.minTick ||
          t.usPerQuarter <= _initialMapTick) {
        return MuseError(
          MuseErrorCode.invalidTickRange,
          'Invalid tempo event at tick ${t.tick.value}: ${t.usPerQuarter}',
        );
      }
    }

    return null;
  }
}
