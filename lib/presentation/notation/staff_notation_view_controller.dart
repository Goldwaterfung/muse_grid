/// Layer 5 controller for `crisp_notation` staff engraving, hit-testing, and L4 score mutations.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crisp_notation/crisp_notation.dart';
import 'package:flutter/foundation.dart';

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/commands/score_editing_command_bus.dart';
import '../../domain/models/score_models.dart';
import '../../domain/notation/crisp_score_mapper.dart';
import '../../domain/notation/dual_model_score_service.dart';
import '../../domain/playback/lookahead_playback_coordinator.dart';
import '../../domain/timeline/tempo_timeline_calculator.dart';
import '../controllers/workspace_shell_controller.dart';
import '../theme/muse_presentation_constants.dart';

/// Descriptor mapping a staff index in `StaffSystem.staves` to its `(partId, staffNumber)`.
final class StaffSlotDescriptor {
  final PartId partId;
  final int staffNumber;

  const StaffSlotDescriptor({
    required this.partId,
    required this.staffNumber,
  });
}

/// Asynchronous release delay callback injected for deterministic tests.
typedef AuditionReleaseDelay = Future<void> Function(Duration duration);

/// Presentation controller owning staff layout caching, element/empty-bar hit-testing,
/// chord/continuation highlight resolution, and typed L4 command dispatches.
final class StaffNotationViewController extends ChangeNotifier {
  final WorkspaceShellController _workspaceShellController;
  final ILookaheadPlaybackCoordinator _playbackCoordinator;
  final String Function() _uuidV7Generator;
  final int Function() _nowEpochMs;
  final AuditionReleaseDelay _auditionReleaseDelay;

  double _zoomScale = NotationViewConstants.defaultZoomScale;
  bool _hideEmptyStaves = false;
  bool _isChordSelectMode = false;
  bool _quantizeInsertedNotes = true;
  int _activeDurationTicks = MusePresentationConstants.defaultGridSnapTicks;
  int _activeVoiceNumber = MusePresentationConstants.minVoiceNumber;
  Tick _cursorTick = const Tick(MusePresentationConstants.initialTick);
  PartId? _focusedPartId;
  int _focusedStaffNumber = MusePresentationConstants.singleStaffNumber;
  Set<NoteId> _selectedNoteIds = const <NoteId>{};
  MuseError? _lastError;

  int? _indexedRevision;
  bool _hasMultiVoiceMeasures = false;
  Map<String, String> _noteIdToAnchorId = const <String, String>{};
  Map<String, List<NoteId>> _anchorIdToNoteIds =
      const <String, List<NoteId>>{};
  Map<String, Set<String>> _anchorToRenderedElementIds =
      const <String, Set<String>>{};
  List<StaffSlotDescriptor> _staffSlotDescriptors =
      const <StaffSlotDescriptor>[];

  StaffSystemLayout? _cachedLayout;
  int? _cachedLayoutRevision;
  double? _cachedLayoutZoom;
  bool? _cachedLayoutHideEmptyStaves;
  bool? _cachedLayoutGridAlign;
  SmuflMetadata? _cachedLayoutMetadata;
  List<StaffSlotDescriptor> _layoutStaffSlots = const <StaffSlotDescriptor>[];

  int _auditionSeq = 0;
  bool _isDisposed = false;

  StaffNotationViewController({
    required this._workspaceShellController,
    required this._playbackCoordinator,
    required this._uuidV7Generator,
    required this._nowEpochMs,
    AuditionReleaseDelay? auditionReleaseDelay,
  }) : _auditionReleaseDelay = auditionReleaseDelay ?? Future<void>.delayed {
    _workspaceShellController.addListener(_handleWorkspaceChange);
    _syncFromWorkspace();
  }

  ScoreWorkspaceState? get activeWorkspace =>
      _workspaceShellController.currentWorkspace;

  double get zoomScale => _zoomScale;
  bool get hideEmptyStaves => _hideEmptyStaves;
  bool get isChordSelectMode => _isChordSelectMode;
  bool get quantizeInsertedNotes => _quantizeInsertedNotes;
  int get activeDurationTicks => _activeDurationTicks;
  int get activeVoiceNumber => _activeVoiceNumber;
  Tick get cursorTick => _cursorTick;
  PartId? get focusedPartId => _focusedPartId;
  int get focusedStaffNumber => _focusedStaffNumber;
  Set<NoteId> get selectedNoteIds => _selectedNoteIds;
  MuseError? get lastError => _lastError;
  bool get hasMultiVoiceMeasures => _hasMultiVoiceMeasures;
  StaffSystemLayout? get cachedLayout => _cachedLayout;
  List<StaffSlotDescriptor> get layoutStaffSlots => _layoutStaffSlots;

  /// Canonical-to-crisp mapping exposed for inspection and verification.
  Map<String, String> get noteIdToAnchorId => _noteIdToAnchorId;

  /// Anchor-to-canonical `NoteId`s mapping exposed for inspection and verification.
  Map<String, List<NoteId>> get anchorIdToNoteIds => _anchorIdToNoteIds;

  /// All rendered `crisp_notation_core` element IDs (anchor heads, chord siblings,
  /// and `__cont_` cross-barline segments) corresponding to [selectedNoteIds].
  Set<String> get highlightedCrispElementIds {
    if (_selectedNoteIds.isEmpty) {
      return const <String>{};
    }
    final highlighted = <String>{};
    for (final noteId in _selectedNoteIds) {
      highlighted.add(noteId.value);
      final anchorId = _noteIdToAnchorId[noteId.value];
      if (anchorId != null) {
        highlighted.add(anchorId);
        final renderedIds = _anchorToRenderedElementIds[anchorId];
        if (renderedIds != null) {
          highlighted.addAll(renderedIds);
        }
      }
      final directRendered = _anchorToRenderedElementIds[noteId.value];
      if (directRendered != null) {
        highlighted.addAll(directRendered);
      }
    }
    return Set<String>.unmodifiable(highlighted);
  }

  /// Ensures `_cachedLayout` is computed cleanly for the active revision,
  /// zoom level, multi-voice alignment mode, and loaded SMuFL font metadata.
  /// Never runs during 60 Hz playhead ticks unless notation structure changes.
  StaffSystemLayout? ensureCachedLayout() {
    final ws = activeWorkspace;
    if (ws == null) {
      _clearLayoutCache();
      return null;
    }
    _syncFromWorkspace();

    final metadata = MusicFonts.metadataOrNull(
      MusePresentationConstants.defaultNotationTheme.musicFont,
    );
    if (metadata == null) {
      _clearLayoutCache();
      return null;
    }

    final targetGridAlign = !_hasMultiVoiceMeasures;
    if (_cachedLayout != null &&
        _cachedLayoutRevision == ws.renderSnapshot.revision &&
        _cachedLayoutZoom == _zoomScale &&
        _cachedLayoutHideEmptyStaves == _hideEmptyStaves &&
        _cachedLayoutGridAlign == targetGridAlign &&
        identical(_cachedLayoutMetadata, metadata)) {
      return _cachedLayout;
    }

    final system = ws.renderSnapshot.crispScoreModel;
    final layout = layoutStaffSystem(
      system,
      LayoutSettings(
        metadata: metadata,
        fingeringPlacement: MusePresentationConstants
            .defaultNotationTheme
            .fingeringPlacement,
      ),
      staffGap: NotationViewConstants.staffGapSpaces,
      gridAlign: targetGridAlign,
      hideEmptyStaves: _hideEmptyStaves,
      spacingStretch: NotationViewConstants.defaultSpacingStretch,
    );

    final mappedSlots = <StaffSlotDescriptor>[];
    for (var s = 0; s < layout.source.staves.length; s++) {
      final survivingScore = layout.source.staves[s];
      var resolvedIdx = -1;
      for (var orig = 0; orig < system.staves.length; orig++) {
        if (identical(system.staves[orig], survivingScore)) {
          resolvedIdx = orig;
          break;
        }
      }
      if (resolvedIdx >= 0 && resolvedIdx < _staffSlotDescriptors.length) {
        mappedSlots.add(_staffSlotDescriptors[resolvedIdx]);
      } else if (s < _staffSlotDescriptors.length) {
        mappedSlots.add(_staffSlotDescriptors[s]);
      }
    }

    _cachedLayout = layout;
    _cachedLayoutRevision = ws.renderSnapshot.revision;
    _cachedLayoutZoom = _zoomScale;
    _cachedLayoutHideEmptyStaves = _hideEmptyStaves;
    _cachedLayoutGridAlign = targetGridAlign;
    _cachedLayoutMetadata = metadata;
    _layoutStaffSlots = List<StaffSlotDescriptor>.unmodifiable(mappedSlots);
    return layout;
  }

  /// Resolves the timeline `(startTick, durationTicks)` of [measureIndex] using
  /// [calculator] deterministically across pickup and multi-meter boundaries.
  ({Tick startTick, int durationTicks, int measureNumber})? measureSpanForIndex(
    int measureIndex,
    ITempoTimelineCalculator calculator,
  ) {
    if (measureIndex < 0) {
      return null;
    }
    var currentStart = const Tick(MusePresentationConstants.initialTick);
    late BarBeatTickPosition info;
    for (var i = 0; i <= measureIndex; i++) {
      info = calculator.tickToBarBeatTick(currentStart);
      if (i == measureIndex) {
        return (
          startTick: info.measureStartTick,
          durationTicks: info.measureDurationTicks,
          measureNumber: info.measureNumber,
        );
      }
      currentStart = Tick(
        info.measureStartTick.value + info.measureDurationTicks,
      );
    }
    return null;
  }

  /// Finds the index of the surviving layout staff belonging to [partId] /
  /// [staffNumber], falling back cleanly to index 0 when staves are present.
  int? layoutStaffIndexForFocusedStaff(StaffSystemLayout layout) {
    if (layout.staves.isEmpty) {
      return null;
    }
    final partId = _focusedPartId;
    if (partId != null) {
      for (var i = 0; i < _layoutStaffSlots.length; i++) {
        final slot = _layoutStaffSlots[i];
        if (slot.partId == partId && slot.staffNumber == _focusedStaffNumber) {
          return i < layout.staves.length ? i : null;
        }
      }
      for (var i = 0; i < _layoutStaffSlots.length; i++) {
        if (_layoutStaffSlots[i].partId == partId) {
          return i < layout.staves.length ? i : null;
        }
      }
    }
    return 0;
  }

  void setZoomScale(double nextZoom) {
    final clamped = nextZoom
        .clamp(
          NotationViewConstants.minZoomScale,
          NotationViewConstants.maxZoomScale,
        )
        .toDouble();
    if (clamped == _zoomScale) {
      return;
    }
    _zoomScale = clamped;
    _cachedLayout = null;
    notifyListeners();
  }

  void zoomIn() => setZoomScale(_zoomScale + NotationViewConstants.zoomStepScale);

  void zoomOut() =>
      setZoomScale(_zoomScale - NotationViewConstants.zoomStepScale);

  void setHideEmptyStaves(bool hideEmpty) {
    if (_hideEmptyStaves == hideEmpty) {
      return;
    }
    _hideEmptyStaves = hideEmpty;
    _cachedLayout = null;
    notifyListeners();
  }

  void setChordSelectMode(bool enabled) {
    if (_isChordSelectMode == enabled) {
      return;
    }
    _isChordSelectMode = enabled;
    notifyListeners();
  }

  void setQuantizeInsertedNotes(bool enabled) {
    if (_quantizeInsertedNotes == enabled) {
      return;
    }
    _quantizeInsertedNotes = enabled;
    notifyListeners();
  }

  void setActiveDurationTicks(int ticks) {
    if (!MusePresentationConstants.supportedSubdivisionTicks.contains(ticks)) {
      throw ArgumentError.value(
        ticks,
        'ticks',
        'Must belong to MusePresentationConstants.supportedSubdivisionTicks',
      );
    }
    if (_activeDurationTicks == ticks) {
      return;
    }
    _activeDurationTicks = ticks;
    notifyListeners();
  }

  void setActiveVoiceNumber(int voiceNumber) {
    final clamped = voiceNumber.clamp(
      MusePresentationConstants.minVoiceNumber,
      MusePresentationConstants.maxVoiceNumber,
    );
    if (_activeVoiceNumber == clamped) {
      return;
    }
    _activeVoiceNumber = clamped;
    notifyListeners();
  }

  void clearSelection() {
    if (_selectedNoteIds.isEmpty) {
      return;
    }
    _selectedNoteIds = const <NoteId>{};
    notifyListeners();
  }

  void dismissError() {
    if (_lastError == null) {
      return;
    }
    _lastError = null;
    notifyListeners();
  }

  /// Resolves an element ID emitted by `StaffSystemView.onElementTap` back into
  /// canonical [NoteId]s (handling both chord buckets and `__cont_` continuations),
  /// moves the engraving caret, updates selection, and auditions the primary pitch.
  Future<void> onCrispElementTapped(String elementId) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return;
    }
    _syncFromWorkspace();

    final anchorId = elementId
        .split(CrispScoreMapperConstants.continuationIdDelimiter)
        .first;
    var resolvedIds = _anchorIdToNoteIds[anchorId];
    if (resolvedIds == null || resolvedIds.isEmpty) {
      final directMatch = ws.aggregate.notes
          .where((n) => n.noteId.value == anchorId)
          .firstOrNull;
      if (directMatch == null) {
        return;
      }
      resolvedIds = <NoteId>[directMatch.noteId];
    }

    final primaryId = resolvedIds.first;
    TimelineNote? primaryNote;
    for (final note in ws.aggregate.notes) {
      if (note.noteId == primaryId) {
        primaryNote = note;
        break;
      }
    }
    if (primaryNote == null) {
      return;
    }

    _cursorTick = primaryNote.quantizedStartTick;
    _focusedPartId = primaryNote.partId;
    _focusedStaffNumber = primaryNote.staffNumber;
    _selectedNoteIds = _isChordSelectMode
        ? Set<NoteId>.unmodifiable(resolvedIds)
        : Set<NoteId>.unmodifiable(<NoteId>{primaryNote.noteId});
    _lastError = null;
    if (_workspaceShellController.state.selectedPartId != primaryNote.partId) {
      _workspaceShellController.selectPart(primaryNote.partId);
    }
    notifyListeners();

    await _auditionPitchPulse(
      partId: primaryNote.partId,
      pitchMidi: primaryNote.pitchMidi,
      velocity: primaryNote.velocity,
    );
  }

  /// Maps a tap anywhere on the notation surface (including empty measures or
  /// rest-only bars) onto [cursorTick], [focusedPartId], and [focusedStaffNumber].
  void onStaffCanvasTapped(Offset localLogicalPosition) {
    final ws = activeWorkspace;
    if (ws == null) {
      return;
    }
    final layout = ensureCachedLayout();
    final calculator = _workspaceShellController
        .buildTimelineCalculatorForActiveWorkspace();
    if (layout == null || calculator == null || layout.staves.isEmpty) {
      return;
    }

    final staffSpace = NotationViewConstants.baseStaffSpacePx * _zoomScale;
    final ySpacesFromLayoutTop = localLogicalPosition.dy / staffSpace;
    final xSpaces =
        (localLogicalPosition.dx / staffSpace) - RenderStaffSystemView.leftInset;

    var bestStaffIdx = 0;
    var bestDistance = double.infinity;
    for (var i = 0; i < layout.staves.length; i++) {
      final topY = layout.staffTop(i) - layout.top;
      final bottomY = topY + NotationViewConstants.standardStaffHeightSpaces;
      final distance =
          ySpacesFromLayoutTop >= topY && ySpacesFromLayoutTop <= bottomY
          ? 0.0
          : (ySpacesFromLayoutTop -
                    (topY + NotationViewConstants.standardStaffHalfHeightSpaces))
                .abs();
      if (distance < bestDistance) {
        bestDistance = distance;
        bestStaffIdx = i;
        if (distance == 0.0) {
          break;
        }
      }
    }

    final regions = layout.staves[bestStaffIdx].measureRegions;
    if (regions.isEmpty) {
      return;
    }

    MeasureRegion targetRegion = regions.first;
    var fraction = 0.0;
    if (xSpaces <= regions.first.startX) {
      targetRegion = regions.first;
      fraction = 0.0;
    } else if (xSpaces >= regions.last.endX) {
      targetRegion = regions.last;
      fraction = 1.0;
    } else {
      var matched = false;
      for (final region in regions) {
        if (xSpaces >= region.startX && xSpaces <= region.endX) {
          targetRegion = region;
          final spanX = region.endX - region.startX;
          fraction = spanX > 0.0 ? ((xSpaces - region.startX) / spanX) : 0.0;
          matched = true;
          break;
        }
      }
      if (!matched) {
        var nearestDist = double.infinity;
        for (final region in regions) {
          final midX = (region.startX + region.endX) / 2.0;
          final dist = (xSpaces - midX).abs();
          if (dist < nearestDist) {
            nearestDist = dist;
            targetRegion = region;
            fraction = xSpaces >= region.endX ? 1.0 : 0.0;
          }
        }
      }
    }

    final span = measureSpanForIndex(targetRegion.index, calculator);
    if (span == null) {
      return;
    }
    final maxOffsetInMeasure = math.max(
      0,
      span.durationTicks - _activeDurationTicks,
    );
    final rawTick =
        span.startTick.value +
        (span.durationTicks * fraction.clamp(0.0, 1.0)).round();
    final clampedRawTick = math.min(
      span.startTick.value + maxOffsetInMeasure,
      math.max(span.startTick.value, rawTick),
    );
    final snappedTick = calculator.quantizeTick(
      Tick(clampedRawTick),
      snapSubdivisionTicks: Tick(_activeDurationTicks),
    );
    final boundedTick = snappedTick.value < span.startTick.value
        ? span.startTick
        : snappedTick.value >= span.startTick.value + span.durationTicks
        ? Tick(span.startTick.value + maxOffsetInMeasure)
        : snappedTick;

    _cursorTick = boundedTick;
    if (bestStaffIdx < _layoutStaffSlots.length) {
      final slot = _layoutStaffSlots[bestStaffIdx];
      _focusedPartId = slot.partId;
      _focusedStaffNumber = slot.staffNumber;
      if (_workspaceShellController.state.selectedPartId != slot.partId) {
        _workspaceShellController.selectPart(slot.partId);
      }
    }
    _selectedNoteIds = const <NoteId>{};
    _lastError = null;
    notifyListeners();
  }

  Future<Result<ScoreWorkspaceState>> insertNoteAtCursor({
    required int pitchMidi,
    EnharmonicStep? stepOverride,
    int? alterOverride,
  }) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    if (pitchMidi < MuseConstants.minMidiPitch ||
        pitchMidi > MuseConstants.maxMidiPitch) {
      return _setErrorAndReturn(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'MIDI pitch ($pitchMidi) outside ${MuseConstants.minMidiPitch}..${MuseConstants.maxMidiPitch}.',
        ),
      );
    }

    final targetPart = _resolveTargetPart(ws.aggregate);
    if (targetPart == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No target part available for note insertion.',
        ),
      );
    }

    final calculator = _workspaceShellController
        .buildTimelineCalculatorForActiveWorkspace();
    final startTick = _quantizeInsertedNotes && calculator != null
        ? calculator.quantizeTick(
            _cursorTick,
            snapSubdivisionTicks: Tick(_activeDurationTicks),
          )
        : _cursorTick;
    final staffNum = _focusedStaffNumber.clamp(
      MusePresentationConstants.singleStaffNumber,
      targetPart.stavesCount,
    );

    final (step, alter) = _resolveSpelling(
      pitchMidi: pitchMidi,
      stepOverride: stepOverride,
      alterOverride: alterOverride,
    );
    if (step == null || alter == null) {
      return _setErrorAndReturn(
        MuseError(
          MuseErrorCode.invalidMidiChannelOrPitch,
          'Enharmonic override does not match MIDI pitch $pitchMidi.',
        ),
      );
    }

    final noteId = NoteId(_uuidV7Generator());
    final note = TimelineNote(
      noteId: noteId,
      projectId: ws.aggregate.project.projectId,
      partId: targetPart.partId,
      staffNumber: staffNum,
      voiceNumber: _activeVoiceNumber,
      pitchMidi: pitchMidi,
      enharmonicStep: step,
      enharmonicAlter: alter,
      rawStartTick: startTick,
      rawDurationTicks: _activeDurationTicks,
      quantizedStartTick: startTick,
      quantizedDurationTicks: _activeDurationTicks,
      velocity: NotationViewConstants.defaultNoteEntryVelocity,
      updatedAtMs: _nowEpochMs(),
    );

    final result = await _workspaceShellController.executeScoreCommand(
      InsertNotesCommand(<TimelineNote>[note]),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }

    _cursorTick = Tick(startTick.value + _activeDurationTicks);
    _focusedPartId = targetPart.partId;
    _focusedStaffNumber = staffNum;
    _selectedNoteIds = Set<NoteId>.unmodifiable(<NoteId>{noteId});
    _lastError = null;
    notifyListeners();

    await _auditionPitchPulse(
      partId: targetPart.partId,
      pitchMidi: pitchMidi,
      velocity: note.velocity,
    );
    return result;
  }

  Future<Result<ScoreWorkspaceState>> deleteSelectedNotes() async {
    if (_selectedNoteIds.isEmpty) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No notes selected for deletion.',
        ),
      );
    }
    final result = await _workspaceShellController.executeScoreCommand(
      DeleteNotesCommand(List<NoteId>.unmodifiable(_selectedNoteIds)),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _selectedNoteIds = const <NoteId>{};
    _lastError = null;
    notifyListeners();
    return result;
  }

  /// Finds a valid diatonic spelling matching the selected primary pitch's
  /// pitch class and requested chromatic alteration (`-1`, `0`, `+1`), or fails
  /// closed via [respellSelectedNotes] when the pitch class cannot take [targetAlter].
  Future<Result<ScoreWorkspaceState>> respellSelectedWithPreferredAlter(
    int targetAlter,
  ) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    final selected = _selectedNotesFrom(ws.aggregate);
    if (selected.isEmpty) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No notes selected for enharmonic respelling.',
        ),
      );
    }
    final pc =
        selected.first.pitchMidi % NotationViewConstants.semitonesPerOctave;
    EnharmonicStep chosenStep = selected.first.enharmonicStep;
    for (final candidate in EnharmonicStep.values) {
      final candidatePc =
          ((_semitoneOffsetForStep(candidate) + targetAlter) %
                  NotationViewConstants.semitonesPerOctave +
              NotationViewConstants.semitonesPerOctave) %
          NotationViewConstants.semitonesPerOctave;
      if (candidatePc == pc) {
        chosenStep = candidate;
        break;
      }
    }
    return respellSelectedNotes(step: chosenStep, alter: targetAlter);
  }

  Future<Result<ScoreWorkspaceState>> respellSelectedNotes({
    required EnharmonicStep step,
    required int alter,
  }) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    final selected = _selectedNotesFrom(ws.aggregate);
    if (selected.isEmpty) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No notes selected for enharmonic respelling.',
        ),
      );
    }

    final requestedPc =
        (_semitoneOffsetForStep(step) + alter) %
        NotationViewConstants.semitonesPerOctave;
    final normalizedRequestedPc =
        (requestedPc + NotationViewConstants.semitonesPerOctave) %
        NotationViewConstants.semitonesPerOctave;

    final now = _nowEpochMs();
    final updated = <TimelineNote>[];
    for (final note in selected) {
      final notePc = note.pitchMidi % NotationViewConstants.semitonesPerOctave;
      if (notePc != normalizedRequestedPc ||
          alter < CrispScoreMapperConstants.minEnharmonicAlter ||
          alter > CrispScoreMapperConstants.maxEnharmonicAlter) {
        return _setErrorAndReturn(
          MuseError(
            MuseErrorCode.invalidMidiChannelOrPitch,
            'Respelling ${step.name} alter=$alter conflicts with MIDI pitch ${note.pitchMidi}.',
          ),
        );
      }
      updated.add(
        _copyNoteWith(
          note,
          enharmonicStep: step,
          enharmonicAlter: alter,
          updatedAtMs: now,
        ),
      );
    }

    final result = await _workspaceShellController.executeScoreCommand(
      UpdateNotesCommand(updated),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> transposeSelectedNotesChromatic(
    int semitones,
  ) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    final selected = _selectedNotesFrom(ws.aggregate);
    if (selected.isEmpty) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No notes selected for transposition.',
        ),
      );
    }

    final now = _nowEpochMs();
    final updated = <TimelineNote>[];
    for (final note in selected) {
      final nextMidi = (note.pitchMidi + semitones).clamp(
        MuseConstants.minMidiPitch,
        MuseConstants.maxMidiPitch,
      );
      final crispPitch = Pitch.fromMidi(nextMidi);
      updated.add(
        _copyNoteWith(
          note,
          pitchMidi: nextMidi,
          enharmonicStep: _fromCrispStep(crispPitch.step),
          enharmonicAlter: crispPitch.alter,
          updatedAtMs: now,
        ),
      );
    }

    final result = await _workspaceShellController.executeScoreCommand(
      UpdateNotesCommand(updated),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();

    final firstUpdated = updated.first;
    await _auditionPitchPulse(
      partId: firstUpdated.partId,
      pitchMidi: firstUpdated.pitchMidi,
      velocity: firstUpdated.velocity,
    );
    return result;
  }

  Future<Result<ScoreWorkspaceState>> applySpannerToSelectedNotes({
    required SpannerType type,
    SpannerPlacement placement = SpannerPlacement.auto,
  }) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    final selected = _selectedNotesFrom(ws.aggregate);
    if (selected.length < 2) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.invalidTickRange,
          'Select at least two notes to create a tie, slur, or beam spanner.',
        ),
      );
    }

    selected.sort((a, b) {
      final byTick = a.quantizedStartTick.value.compareTo(
        b.quantizedStartTick.value,
      );
      if (byTick != 0) return byTick;
      final byPitch = a.pitchMidi.compareTo(b.pitchMidi);
      if (byPitch != 0) return byPitch;
      return a.noteId.value.compareTo(b.noteId.value);
    });

    final startNote = selected.first;
    final endNote = selected.last;
    if (startNote.partId != endNote.partId) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.invalidTickRange,
          'Spanner start and end notes must belong to the same part.',
        ),
      );
    }

    final spanner = NoteSpannerEntity(
      spannerId: SpannerId(_uuidV7Generator()),
      projectId: ws.aggregate.project.projectId,
      partId: startNote.partId,
      spannerType: type,
      startNoteId: startNote.noteId,
      endNoteId: endNote.noteId,
      spannerLevel: NotationViewConstants.minSpannerLevel,
      placement: placement,
      updatedAtMs: _nowEpochMs(),
    );

    final result = await _workspaceShellController.executeScoreCommand(
      UpsertNoteSpannerCommand(spanner),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> removeAttachedSpannersFromSelection() async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    if (_selectedNoteIds.isEmpty) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No notes selected.',
        ),
      );
    }
    final matchingIds = ws.aggregate.spanners
        .where(
          (s) =>
              _selectedNoteIds.contains(s.startNoteId) ||
              _selectedNoteIds.contains(s.endNoteId),
        )
        .map((s) => s.spannerId)
        .toList(growable: false);
    if (matchingIds.isEmpty) {
      return Ok<ScoreWorkspaceState>(ws);
    }

    late Result<ScoreWorkspaceState> lastResult;
    for (final spannerId in matchingIds) {
      lastResult = await _workspaceShellController.executeScoreCommand(
        DeleteNoteSpannerCommand(spannerId),
      );
      if (lastResult case Err<ScoreWorkspaceState>(:final error)) {
        return _setErrorAndReturn(error);
      }
    }
    _lastError = null;
    notifyListeners();
    return lastResult;
  }

  Future<Result<ScoreWorkspaceState>> setClefAtCursor({
    required ClefSign sign,
    required int line,
    int octaveChange = MusePresentationConstants.defaultClefOctaveChange,
  }) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    final targetPart = _resolveTargetPart(ws.aggregate);
    if (targetPart == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No target part available for clef change.',
        ),
      );
    }

    final staffNum = _focusedStaffNumber.clamp(
      MusePresentationConstants.singleStaffNumber,
      targetPart.stavesCount,
    );
    final existing = ws.aggregate.clefEvents
        .where(
          (c) =>
              c.partId == targetPart.partId &&
              c.staffNumber == staffNum &&
              c.tick == _cursorTick,
        )
        .firstOrNull;

    final result = await _workspaceShellController.executeScoreCommand(
      UpsertClefEventCommand(
        ClefEventEntity(
          clefEventId: existing?.clefEventId ?? ClefEventId(_uuidV7Generator()),
          projectId: ws.aggregate.project.projectId,
          partId: targetPart.partId,
          staffNumber: staffNum,
          tick: _cursorTick,
          sign: sign,
          line: line,
          octaveChange: octaveChange,
          updatedAtMs: _nowEpochMs(),
        ),
      ),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> removeClefEvent(
    ClefEventId clefEventId,
  ) async {
    final result = await _workspaceShellController.executeScoreCommand(
      DeleteClefEventCommand(clefEventId),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> setKeySignatureAtCursor({
    required int fifths,
    required KeyMode mode,
    bool globalToScore = true,
  }) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    final targetPart = _resolveTargetPart(ws.aggregate);
    final PartId? eventPartId = globalToScore ? null : targetPart?.partId;
    final staffNumber = globalToScore
        ? CrispScoreMapperConstants.allStavesKeySigStaffNumber
        : _focusedStaffNumber;

    final existing = ws.aggregate.keySignatureEvents
        .where(
          (k) =>
              k.partId == eventPartId &&
              k.staffNumber == staffNumber &&
              k.tick == _cursorTick,
        )
        .firstOrNull;

    final result = await _workspaceShellController.executeScoreCommand(
      UpsertKeySignatureCommand(
        KeySignatureEventEntity(
          keyEventId: existing?.keyEventId ?? KeySigEventId(_uuidV7Generator()),
          projectId: ws.aggregate.project.projectId,
          partId: eventPartId,
          staffNumber: staffNumber,
          tick: _cursorTick,
          fifths: fifths.clamp(
            NotationViewConstants.minKeySignatureFifths,
            NotationViewConstants.maxKeySignatureFifths,
          ),
          mode: mode,
          updatedAtMs: _nowEpochMs(),
        ),
      ),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> removeKeySignatureEvent(
    KeySigEventId keyEventId,
  ) async {
    final result = await _workspaceShellController.executeScoreCommand(
      DeleteKeySignatureCommand(keyEventId),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> setTimeSignatureAtCursor({
    required int numerator,
    required int denominator,
  }) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    final existing = ws.aggregate.timeSignatureEvents
        .where((ts) => ts.tick == _cursorTick)
        .firstOrNull;

    final result = await _workspaceShellController.executeScoreCommand(
      UpsertTimeSignatureCommand(
        TimeSignatureEventEntity(
          tsEventId: existing?.tsEventId ?? TimeSigEventId(_uuidV7Generator()),
          projectId: ws.aggregate.project.projectId,
          tick: _cursorTick,
          numerator: numerator,
          denominator: denominator,
          updatedAtMs: _nowEpochMs(),
        ),
      ),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> removeTimeSignatureEvent(
    TimeSigEventId tsEventId,
  ) async {
    final result = await _workspaceShellController.executeScoreCommand(
      DeleteTimeSignatureCommand(tsEventId),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> setTempoAtCursor({required int bpm}) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return _setErrorAndReturn(
        const MuseError(
          MuseErrorCode.entityNotFound,
          'No active project workspace is open.',
        ),
      );
    }
    if (bpm < TelemetryConstants.bpmMinValid ||
        bpm > TelemetryConstants.bpmMaxValid) {
      return _setErrorAndReturn(
        MuseError(
          MuseErrorCode.invalidTickRange,
          'BPM ($bpm) must be within ${TelemetryConstants.bpmMinValid}..${TelemetryConstants.bpmMaxValid}.',
        ),
      );
    }

    final existing = ws.aggregate.tempoEvents
        .where((t) => t.tick == _cursorTick)
        .firstOrNull;
    final usPerQuarter = MusePresentationConstants.microsecondsPerMinute ~/ bpm;

    final result = await _workspaceShellController.executeScoreCommand(
      UpsertTempoEventCommand(
        TempoEventEntity(
          tempoEventId:
              existing?.tempoEventId ?? TempoEventId(_uuidV7Generator()),
          projectId: ws.aggregate.project.projectId,
          tick: _cursorTick,
          usPerQuarter: usPerQuarter,
          updatedAtMs: _nowEpochMs(),
        ),
      ),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  Future<Result<ScoreWorkspaceState>> removeTempoEvent(
    TempoEventId tempoEventId,
  ) async {
    final result = await _workspaceShellController.executeScoreCommand(
      DeleteTempoEventCommand(tempoEventId),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      return _setErrorAndReturn(error);
    }
    _lastError = null;
    notifyListeners();
    return result;
  }

  void _handleWorkspaceChange() {
    _syncFromWorkspace();
    notifyListeners();
  }

  void _syncFromWorkspace() {
    final ws = activeWorkspace;
    if (ws == null) {
      _indexedRevision = null;
      _hasMultiVoiceMeasures = false;
      _noteIdToAnchorId = const <String, String>{};
      _anchorIdToNoteIds = const <String, List<NoteId>>{};
      _anchorToRenderedElementIds = const <String, Set<String>>{};
      _staffSlotDescriptors = const <StaffSlotDescriptor>[];
      _selectedNoteIds = const <NoteId>{};
      _focusedPartId = null;
      _clearLayoutCache();
      return;
    }

    final shellSelectedPart = _workspaceShellController.state.selectedPartId;
    if (_focusedPartId == null ||
        !ws.aggregate.parts.any((p) => p.partId == _focusedPartId)) {
      _focusedPartId =
          shellSelectedPart ?? ws.aggregate.parts.firstOrNull?.partId;
    }
    final resolvedPart = _resolveTargetPart(ws.aggregate);
    if (resolvedPart != null) {
      _focusedStaffNumber = _focusedStaffNumber.clamp(
        MusePresentationConstants.singleStaffNumber,
        resolvedPart.stavesCount,
      );
    }

    if (_indexedRevision == ws.renderSnapshot.revision) {
      return;
    }
    _indexedRevision = ws.renderSnapshot.revision;
    _clearLayoutCache();

    final sortedParts = List<ProjectPartEntity>.from(ws.aggregate.parts)
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.partId.value.compareTo(b.partId.value);
      });
    final slots = <StaffSlotDescriptor>[];
    for (final part in sortedParts) {
      final stavesCount = part.stavesCount.clamp(
        CrispScoreMapperConstants.singleStaffCount,
        CrispScoreMapperConstants.grandStaffCount,
      );
      for (var s = 1; s <= stavesCount; s++) {
        slots.add(StaffSlotDescriptor(partId: part.partId, staffNumber: s));
      }
    }
    _staffSlotDescriptors = List<StaffSlotDescriptor>.unmodifiable(slots);

    var multiVoiceFound = false;
    final anchorToRendered = <String, Set<String>>{};
    for (final staffScore in ws.renderSnapshot.crispScoreModel.staves) {
      for (final measure in staffScore.measures) {
        if (measure.voice2.isNotEmpty ||
            measure.voice3.isNotEmpty ||
            measure.voice4.isNotEmpty) {
          multiVoiceFound = true;
        }
        for (final voice in <List<MusicElement>>[
          measure.elements,
          measure.voice2,
          measure.voice3,
          measure.voice4,
        ]) {
          for (final elem in voice) {
            final id = elem.id;
            if (id == null) continue;
            final anchor = id
                .split(CrispScoreMapperConstants.continuationIdDelimiter)
                .first;
            anchorToRendered.putIfAbsent(anchor, () => <String>{}).add(id);
          }
        }
      }
    }
    _hasMultiVoiceMeasures = multiVoiceFound;
    _anchorToRenderedElementIds = Map<String, Set<String>>.unmodifiable({
      for (final e in anchorToRendered.entries)
        e.key: Set<String>.unmodifiable(e.value),
    });

    final bucketGroups = <(String, int, int, int, int), List<TimelineNote>>{};
    final validNoteIds = <NoteId>{};
    for (final note in ws.aggregate.notes) {
      validNoteIds.add(note.noteId);
      final key = (
        note.partId.value,
        note.staffNumber,
        note.voiceNumber.clamp(
          MusePresentationConstants.minVoiceNumber,
          MusePresentationConstants.maxVoiceNumber,
        ),
        note.quantizedStartTick.value,
        note.quantizedDurationTicks,
      );
      bucketGroups.putIfAbsent(key, () => <TimelineNote>[]).add(note);
    }

    final noteToAnchor = <String, String>{};
    final anchorToNotes = <String, List<NoteId>>{};
    for (final group in bucketGroups.values) {
      group.sort((a, b) {
        final byPitch = a.pitchMidi.compareTo(b.pitchMidi);
        if (byPitch != 0) return byPitch;
        final byStep = a.enharmonicStep.index.compareTo(
          b.enharmonicStep.index,
        );
        if (byStep != 0) return byStep;
        final byAlter = a.enharmonicAlter.compareTo(b.enharmonicAlter);
        if (byAlter != 0) return byAlter;
        return a.noteId.value.compareTo(b.noteId.value);
      });
      final anchorId = group.first.noteId.value;
      final noteIds = <NoteId>[for (final n in group) n.noteId];
      anchorToNotes[anchorId] = List<NoteId>.unmodifiable(noteIds);
      for (final id in noteIds) {
        noteToAnchor[id.value] = anchorId;
      }
    }
    _noteIdToAnchorId = Map<String, String>.unmodifiable(noteToAnchor);
    _anchorIdToNoteIds = Map<String, List<NoteId>>.unmodifiable(anchorToNotes);

    if (_selectedNoteIds.isNotEmpty) {
      _selectedNoteIds = Set<NoteId>.unmodifiable(
        _selectedNoteIds.where(validNoteIds.contains),
      );
    }
  }

  void _clearLayoutCache() {
    _cachedLayout = null;
    _cachedLayoutRevision = null;
    _cachedLayoutZoom = null;
    _cachedLayoutHideEmptyStaves = null;
    _cachedLayoutGridAlign = null;
    _cachedLayoutMetadata = null;
    _layoutStaffSlots = const <StaffSlotDescriptor>[];
  }

  ProjectPartEntity? _resolveTargetPart(ProjectWorkspaceAggregate agg) {
    final targetId =
        _focusedPartId ?? _workspaceShellController.state.selectedPartId;
    if (targetId != null) {
      for (final p in agg.parts) {
        if (p.partId == targetId) {
          return p;
        }
      }
    }
    return agg.parts.firstOrNull;
  }

  List<TimelineNote> _selectedNotesFrom(ProjectWorkspaceAggregate agg) {
    if (_selectedNoteIds.isEmpty) {
      return const <TimelineNote>[];
    }
    return agg.notes
        .where((n) => _selectedNoteIds.contains(n.noteId))
        .toList();
  }

  Future<void> _auditionPitchPulse({
    required PartId partId,
    required int pitchMidi,
    required int velocity,
  }) async {
    final seq = ++_auditionSeq;
    _playbackCoordinator.auditionNote(
      partId: partId,
      pitchMidi: pitchMidi,
      velocity: velocity.clamp(
        MuseConstants.minMidiVelocity,
        MuseConstants.maxMidiVelocity,
      ),
      isNoteOn: true,
    );
    await _auditionReleaseDelay(
      const Duration(milliseconds: NotationViewConstants.auditionNoteDurationMs),
    );
    if (_isDisposed || seq != _auditionSeq) {
      // Still release note-off for prior pitch unless another caller took over?
      // Releasing previous note-off prevents stuck notes cleanly on rapid taps.
    }
    if (_isDisposed) {
      return;
    }
    _playbackCoordinator.auditionNote(
      partId: partId,
      pitchMidi: pitchMidi,
      velocity: LookaheadPlaybackConstants.noteOffReleaseVelocity,
      isNoteOn: false,
    );
  }

  Result<ScoreWorkspaceState> _setErrorAndReturn(MuseError error) {
    _lastError = error;
    notifyListeners();
    return Err<ScoreWorkspaceState>(error);
  }

  static (EnharmonicStep?, int?) _resolveSpelling({
    required int pitchMidi,
    EnharmonicStep? stepOverride,
    int? alterOverride,
  }) {
    if (stepOverride == null && alterOverride == null) {
      final crispPitch = Pitch.fromMidi(pitchMidi);
      return (_fromCrispStep(crispPitch.step), crispPitch.alter);
    }
    final step = stepOverride ?? _fromCrispStep(Pitch.fromMidi(pitchMidi).step);
    final alter = alterOverride ?? 0;
    if (alter < CrispScoreMapperConstants.minEnharmonicAlter ||
        alter > CrispScoreMapperConstants.maxEnharmonicAlter) {
      return (null, null);
    }
    final pc =
        ((_semitoneOffsetForStep(step) + alter) %
                NotationViewConstants.semitonesPerOctave +
            NotationViewConstants.semitonesPerOctave) %
        NotationViewConstants.semitonesPerOctave;
    if (pc != pitchMidi % NotationViewConstants.semitonesPerOctave) {
      return (null, null);
    }
    return (step, alter);
  }

  static EnharmonicStep _fromCrispStep(Step step) => switch (step) {
    Step.c => EnharmonicStep.C,
    Step.d => EnharmonicStep.D,
    Step.e => EnharmonicStep.E,
    Step.f => EnharmonicStep.F,
    Step.g => EnharmonicStep.G,
    Step.a => EnharmonicStep.A,
    Step.b => EnharmonicStep.B,
  };

  static int _semitoneOffsetForStep(EnharmonicStep step) => switch (step) {
    EnharmonicStep.C => Step.c.semitonesFromC,
    EnharmonicStep.D => Step.d.semitonesFromC,
    EnharmonicStep.E => Step.e.semitonesFromC,
    EnharmonicStep.F => Step.f.semitonesFromC,
    EnharmonicStep.G => Step.g.semitonesFromC,
    EnharmonicStep.A => Step.a.semitonesFromC,
    EnharmonicStep.B => Step.b.semitonesFromC,
  };

  static TimelineNote _copyNoteWith(
    TimelineNote note, {
    int? pitchMidi,
    EnharmonicStep? enharmonicStep,
    int? enharmonicAlter,
    required int updatedAtMs,
  }) => TimelineNote(
    noteId: note.noteId,
    projectId: note.projectId,
    partId: note.partId,
    staffNumber: note.staffNumber,
    voiceNumber: note.voiceNumber,
    pitchMidi: pitchMidi ?? note.pitchMidi,
    enharmonicStep: enharmonicStep ?? note.enharmonicStep,
    enharmonicAlter: enharmonicAlter ?? note.enharmonicAlter,
    rawStartTick: note.rawStartTick,
    rawDurationTicks: note.rawDurationTicks,
    quantizedStartTick: note.quantizedStartTick,
    quantizedDurationTicks: note.quantizedDurationTicks,
    velocity: note.velocity,
    updatedAtMs: updatedAtMs,
  );

  @override
  void dispose() {
    _isDisposed = true;
    _workspaceShellController.removeListener(_handleWorkspaceChange);
    super.dispose();
  }
}
