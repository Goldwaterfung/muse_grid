/// Layer 5 controller for Piano Roll viewport culling, dynamic grid LOD,
/// ephemeral pointer gestures, and L4 score/playback dispatches.
library;

import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';

import 'package:crisp_notation/crisp_notation.dart' show Pitch, Step;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart' show kMiddleMouseButton;

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/commands/score_editing_command_bus.dart';
import '../../domain/models/score_models.dart';
import '../../domain/notation/dual_model_score_service.dart';
import '../../domain/playback/lookahead_playback_coordinator.dart';
import '../../domain/timeline/tempo_timeline_calculator.dart';
import '../controllers/workspace_shell_controller.dart';
import '../theme/muse_presentation_constants.dart';

/// Active editing tool inside [PianoRollPanel].
enum PianoRollToolMode { select, draw, erase, pan }

/// Ephemeral note drag/draw/resize preview rendered without intermediate DB commits.
final class PianoRollDragNotePreview {
  final NoteId? noteId;
  final Tick startTick;
  final int durationTicks;
  final int pitchMidi;
  final int velocity;
  final bool isNewNote;

  const PianoRollDragNotePreview({
    required this.noteId,
    required this.startTick,
    required this.durationTicks,
    required this.pitchMidi,
    required this.velocity,
    required this.isNewNote,
  });

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PianoRollDragNotePreview &&
          noteId == other.noteId &&
          startTick == other.startTick &&
          durationTicks == other.durationTicks &&
          pitchMidi == other.pitchMidi &&
          velocity == other.velocity &&
          isNewNote == other.isNewNote;

  @override
  int get hashCode => Object.hash(
    noteId,
    startTick,
    durationTicks,
    pitchMidi,
    velocity,
    isNewNote,
  );
}

/// Culled visible viewport snapshot computed from the L4 $O(\log N + K)$ spatial index.
final class PianoRollVisibleSlice {
  final int workspaceRevision;
  final PartId? partId;
  final Tick visibleStartTick;
  final Tick visibleEndTick;
  final int visibleMinPitchMidi;
  final int visibleMaxPitchMidi;
  final int effectiveSubdivisionTicks;
  final List<TimelineNote> visibleNotes;
  final List<BarBeatGridLine> gridLines;
  final AudioTakeEntity? activeTake;
  final Tick? takeStartTick;
  final Tick? takeDurationTicks;

  const PianoRollVisibleSlice({
    required this.workspaceRevision,
    required this.partId,
    required this.visibleStartTick,
    required this.visibleEndTick,
    required this.visibleMinPitchMidi,
    required this.visibleMaxPitchMidi,
    required this.effectiveSubdivisionTicks,
    required this.visibleNotes,
    required this.gridLines,
    required this.activeTake,
    required this.takeStartTick,
    required this.takeDurationTicks,
  });

  static const PianoRollVisibleSlice empty = PianoRollVisibleSlice(
    workspaceRevision: 0,
    partId: null,
    visibleStartTick: Tick(0),
    visibleEndTick: Tick(1),
    visibleMinPitchMidi: PianoRollLayoutConstants.minPitchMidi,
    visibleMaxPitchMidi: PianoRollLayoutConstants.maxPitchMidi,
    effectiveSubdivisionTicks: MusePresentationConstants.defaultGridSnapTicks,
    visibleNotes: <TimelineNote>[],
    gridLines: <BarBeatGridLine>[],
    activeTake: null,
    takeStartTick: null,
    takeDurationTicks: null,
  );
}

enum _DragGestureKind { none, drawNote, moveNotes, resizeNote, marquee, pan }

/// Presentation controller managing culled Piano Roll viewports, zoom-dependent LOD,
/// synchronous pointer gestures, and reversible `ScoreCommand` emission on release.
final class PianoRollViewportController extends ChangeNotifier {
  final WorkspaceShellController _workspaceShellController;
  final IDualModelScoreService _dualModelScoreService;
  final ILookaheadPlaybackCoordinator _playbackCoordinator;
  final String Function() _uuidV7Generator;
  final int Function() _nowEpochMs;

  double _scrollXpx = PianoRollLayoutConstants.minScrollPx;
  double _scrollYpx = PianoRollLayoutConstants.minScrollPx;
  double _viewportWidthPx = PianoRollLayoutConstants.defaultViewportWidthPx;
  double _viewportHeightPx = PianoRollLayoutConstants.defaultViewportHeightPx;
  double _pixelsPerTick = PianoRollLayoutConstants.defaultPixelsPerTick;
  double _rowHeightPx = PianoRollLayoutConstants.defaultRowHeightPx;
  int _selectedSnapTicks = MusePresentationConstants.defaultGridSnapTicks;
  PianoRollToolMode _activeTool = PianoRollToolMode.select;
  int _defaultVelocity = NotationViewConstants.defaultNoteEntryVelocity;
  Set<NoteId> _selectedNoteIds = const <NoteId>{};
  List<PianoRollDragNotePreview> _dragPreviews =
      const <PianoRollDragNotePreview>[];
  Rect? _marqueeRectViewportPx;
  MuseError? _lastError;

  ProjectId? _lastSyncedProjectId;
  int? _lastSyncedProjectGridSnapTicks;
  PartId? _lastSyncedSelectedPartId;

  _DragGestureKind _dragKind = _DragGestureKind.none;
  Tick _dragAnchorTick = const Tick(0);
  int _dragAnchorPitchMidi = NotationViewConstants.middleCMidiPitch;
  Offset? _marqueeStartViewportPx;
  Offset? _panLastViewportPos;
  List<TimelineNote> _dragOriginalNotes = const <TimelineNote>[];
  TimelineNote? _resizeOriginalNote;

  PartId? _auditionedPartId;
  int? _auditionedPitchMidi;
  bool _hasInitializedScrollY = false;
  bool _isDisposed = false;

  PianoRollViewportController({
    required this._workspaceShellController,
    required this._dualModelScoreService,
    required this._playbackCoordinator,
    required this._uuidV7Generator,
    required this._nowEpochMs,
  }) {
    _workspaceShellController.addListener(_handleWorkspaceChange);
    _syncFromWorkspace(initial: true);
  }

  ScoreWorkspaceState? get activeWorkspace =>
      _workspaceShellController.currentWorkspace;

  PartId? get activePartId {
    final ws = activeWorkspace;
    if (ws == null) {
      return null;
    }
    final selected = _workspaceShellController.state.selectedPartId;
    if (selected != null &&
        ws.aggregate.parts.any((part) => part.partId == selected)) {
      return selected;
    }
    return ws.aggregate.parts.firstOrNull?.partId;
  }

  double get scrollXpx => _scrollXpx;
  double get scrollYpx => _scrollYpx;
  double get viewportWidthPx => _viewportWidthPx;
  double get viewportHeightPx => _viewportHeightPx;
  double get pixelsPerTick => _pixelsPerTick;
  double get rowHeightPx => _rowHeightPx;
  int get selectedSnapTicks => _selectedSnapTicks;
  PianoRollToolMode get activeTool => _activeTool;
  int get defaultVelocity => _defaultVelocity;
  Set<NoteId> get selectedNoteIds => _selectedNoteIds;
  List<PianoRollDragNotePreview> get dragPreviews => _dragPreviews;
  Rect? get marqueeRectViewportPx => _marqueeRectViewportPx;
  MuseError? get lastError => _lastError;
  bool get isPanning => _dragKind == _DragGestureKind.pan;
  bool get hasInitializedScrollY => _hasInitializedScrollY;

  double get maxScrollXpx => math.max(
    PianoRollLayoutConstants.minScrollPx,
    totalCanvasWidthPx - _viewportWidthPx,
  );

  double get maxScrollYpx => math.max(
    PianoRollLayoutConstants.minScrollPx,
    totalCanvasHeightPx - _viewportHeightPx,
  );

  Tick get visibleStartTick => Tick(math.max(0, (_scrollXpx / _pixelsPerTick).floor()));

  Tick get visibleEndTick => Tick(
    math.max(
      visibleStartTick.value + 1,
      ((_scrollXpx + _viewportWidthPx) / _pixelsPerTick).ceil(),
    ),
  );

  int get visibleMaxPitchMidi =>
      (PianoRollLayoutConstants.maxPitchMidi - (_scrollYpx / _rowHeightPx).floor())
          .clamp(
            PianoRollLayoutConstants.minPitchMidi,
            PianoRollLayoutConstants.maxPitchMidi,
          );

  int get visibleMinPitchMidi =>
      (PianoRollLayoutConstants.maxPitchMidi -
              ((_scrollYpx + _viewportHeightPx) / _rowHeightPx).ceil())
          .clamp(
            PianoRollLayoutConstants.minPitchMidi,
            PianoRollLayoutConstants.maxPitchMidi,
          );

  Tick screenXToTick(double localX) =>
      Tick(math.max(0, ((_scrollXpx + localX) / _pixelsPerTick).round()));

  int screenYToPitchMidi(double localY) =>
      (PianoRollLayoutConstants.maxPitchMidi -
              ((_scrollYpx + localY) / _rowHeightPx).floor())
          .clamp(
            PianoRollLayoutConstants.minPitchMidi,
            PianoRollLayoutConstants.maxPitchMidi,
          );

  double get totalCanvasHeightPx =>
      PianoRollLayoutConstants.totalPitchRows * _rowHeightPx;

  double get totalCanvasWidthPx {
    final ws = activeWorkspace;
    final defaultBarTicks = MuseConstants.wholeNoteTicks;
    var maxEndTick =
        PianoRollLayoutConstants.minimumCanvasBars * defaultBarTicks;
    if (ws != null) {
      final timingMode = ws.aggregate.project.playbackTimingMode;
      final partId = activePartId;
      for (final note in ws.aggregate.notes) {
        if (partId != null && note.partId != partId) continue;
        final end = timingMode == PlaybackTimingMode.raw
            ? note.rawStartTick.value + note.rawDurationTicks
            : note.quantizedStartTick.value + note.quantizedDurationTicks;
        if (end > maxEndTick) {
          maxEndTick = end;
        }
      }
      final calculator = _workspaceShellController
          .buildTimelineCalculatorForActiveWorkspace();
      if (partId != null && calculator != null) {
        for (final take in ws.aggregate.audioTakes) {
          if (take.partId != partId) continue;
          final takeEndTick = _computeTakeDurationTicks(take, calculator).value +
              take.startTick.value;
          if (takeEndTick > maxEndTick) {
            maxEndTick = takeEndTick;
          }
        }
      }
    }
    return (maxEndTick + PianoRollLayoutConstants.horizontalPaddingTicks) *
        _pixelsPerTick;
  }

  /// Resolves the readable grid subdivision strictly via exact set membership on
  /// [PianoRollLayoutConstants.tripletSubdivisionTicks] and
  /// [PianoRollLayoutConstants.dottedSubdivisionTicks] (never `%` modulo!).
  int computeEffectiveGridSubdivisionTicks() {
    final List<int> ladder;
    if (PianoRollLayoutConstants.tripletSubdivisionTicks.contains(
      _selectedSnapTicks,
    )) {
      ladder = PianoRollLayoutConstants.tripletLodLadderTicks;
    } else if (PianoRollLayoutConstants.dottedSubdivisionTicks.contains(
      _selectedSnapTicks,
    )) {
      ladder = PianoRollLayoutConstants.dottedLodLadderTicks;
    } else {
      ladder = PianoRollLayoutConstants.straightLodLadderTicks;
    }

    var startIndex = ladder.indexWhere((rung) => rung >= _selectedSnapTicks);
    if (startIndex < 0) {
      startIndex = ladder.length - 1;
    }

    for (var i = startIndex; i < ladder.length; i++) {
      final candidate = ladder[i];
      if (candidate * _pixelsPerTick >=
          PianoRollLayoutConstants.minReadableGridLineSpacingPx) {
        return candidate;
      }
    }
    return ladder.last;
  }

  /// Queries only notes, grid lines, and take bounds intersecting the current viewport.
  PianoRollVisibleSlice computeVisibleSlice() {
    final ws = activeWorkspace;
    final partId = activePartId;
    if (ws == null || partId == null) {
      return PianoRollVisibleSlice.empty;
    }
    final calculator = _workspaceShellController
        .buildTimelineCalculatorForActiveWorkspace();
    if (calculator == null) {
      return PianoRollVisibleSlice.empty;
    }

    final startTick = visibleStartTick;
    final endTick = visibleEndTick;
    final minPitch = visibleMinPitchMidi;
    final maxPitch = visibleMaxPitchMidi;
    final effectiveSub = computeEffectiveGridSubdivisionTicks();

    final visibleNotes = _dualModelScoreService.queryNotesInViewport(
      state: ws,
      partId: partId,
      startTick: startTick,
      endTick: endTick,
      minPitchMidi: minPitch,
      maxPitchMidi: maxPitch,
      timingMode: ws.aggregate.project.playbackTimingMode,
    );

    final gridLines = calculator.queryVisibleGridLines(
      startTick: startTick,
      endTick: endTick,
      subdivisionTicks: Tick(effectiveSub),
    );

    AudioTakeEntity? activeTake;
    for (final take in ws.aggregate.audioTakes) {
      if (take.partId == partId) {
        activeTake = take;
        break;
      }
    }

    Tick? takeStartTick;
    Tick? takeDurationTicks;
    if (activeTake != null) {
      takeStartTick = activeTake.startTick;
      takeDurationTicks = _computeTakeDurationTicks(activeTake, calculator);
    }

    return PianoRollVisibleSlice(
      workspaceRevision: ws.renderSnapshot.revision,
      partId: partId,
      visibleStartTick: startTick,
      visibleEndTick: endTick,
      visibleMinPitchMidi: minPitch,
      visibleMaxPitchMidi: maxPitch,
      effectiveSubdivisionTicks: effectiveSub,
      visibleNotes: visibleNotes,
      gridLines: gridLines,
      activeTake: activeTake,
      takeStartTick: takeStartTick,
      takeDurationTicks: takeDurationTicks,
    );
  }

  /// Updates viewport dimensions and/or clamped scroll offsets.
  void updateViewportGeometry({
    double? scrollXpx,
    double? scrollYpx,
    double? viewportWidthPx,
    double? viewportHeightPx,
    bool centerInitialPitchIfUnset = false,
  }) {
    final nextWidth = viewportWidthPx == null
        ? _viewportWidthPx
        : math.max(
            PianoRollLayoutConstants.minViewportExtentPx,
            viewportWidthPx,
          );
    final nextHeight = viewportHeightPx == null
        ? _viewportHeightPx
        : math.max(
            PianoRollLayoutConstants.minViewportExtentPx,
            viewportHeightPx,
          );

    final prevWidth = _viewportWidthPx;
    final prevHeight = _viewportHeightPx;
    _viewportWidthPx = nextWidth;
    _viewportHeightPx = nextHeight;

    final maxX = maxScrollXpx;
    final maxY = maxScrollYpx;

    final nextScrollX = (scrollXpx ?? _scrollXpx)
        .clamp(PianoRollLayoutConstants.minScrollPx, maxX)
        .toDouble();

    final double rawNextScrollY;
    var nextInitializedScrollY = _hasInitializedScrollY;
    if (scrollYpx != null) {
      rawNextScrollY = scrollYpx;
      nextInitializedScrollY = true;
    } else if (centerInitialPitchIfUnset && !_hasInitializedScrollY) {
      rawNextScrollY = _centeredScrollYForPitch(
        PianoRollLayoutConstants.initialScrollCenterPitchMidi,
      );
      nextInitializedScrollY = true;
    } else {
      rawNextScrollY = _scrollYpx;
    }
    final nextScrollY = rawNextScrollY
        .clamp(PianoRollLayoutConstants.minScrollPx, maxY)
        .toDouble();

    final changed =
        nextScrollX != _scrollXpx ||
        nextScrollY != _scrollYpx ||
        nextWidth != prevWidth ||
        nextHeight != prevHeight;
    _scrollXpx = nextScrollX;
    _scrollYpx = nextScrollY;
    _hasInitializedScrollY = nextInitializedScrollY;

    if (changed) {
      notifyListeners();
    }
  }

  /// Sets absolute horizontal and/or vertical scroll offsets (clamped to canvas bounds).
  void scrollTo({double? scrollXpx, double? scrollYpx}) {
    updateViewportGeometry(scrollXpx: scrollXpx, scrollYpx: scrollYpx);
  }

  /// Pans the viewport by pixel deltas along horizontal and/or vertical axes.
  void panBy({double dxPx = 0.0, double dyPx = 0.0}) {
    if (dxPx == 0.0 && dyPx == 0.0) {
      return;
    }
    updateViewportGeometry(
      scrollXpx: dxPx != 0.0 ? _scrollXpx + dxPx : null,
      scrollYpx: dyPx != 0.0 ? _scrollYpx + dyPx : null,
    );
  }

  /// Centers the vertical viewport around [pitchMidi].
  void centerOnPitchMidi(int pitchMidi) {
    final clampedPitch = pitchMidi.clamp(
      PianoRollLayoutConstants.minPitchMidi,
      PianoRollLayoutConstants.maxPitchMidi,
    );
    updateViewportGeometry(scrollYpx: _centeredScrollYForPitch(clampedPitch));
  }

  double _centeredScrollYForPitch(int pitchMidi) {
    final pitchCenterOffset =
        (PianoRollLayoutConstants.maxPitchMidi -
            pitchMidi +
            PianoRollLayoutConstants.viewportCenterFraction) *
        _rowHeightPx;
    final raw =
        pitchCenterOffset -
        _viewportHeightPx * PianoRollLayoutConstants.viewportCenterFraction;
    return raw
        .clamp(PianoRollLayoutConstants.minScrollPx, maxScrollYpx)
        .toDouble();
  }

  void setPixelsPerTick(double value) {
    final clamped = value
        .clamp(
          PianoRollLayoutConstants.minPixelsPerTick,
          PianoRollLayoutConstants.maxPixelsPerTick,
        )
        .toDouble();
    if (clamped == _pixelsPerTick) {
      return;
    }
    _pixelsPerTick = clamped;
    _scrollXpx = _scrollXpx
        .clamp(PianoRollLayoutConstants.minScrollPx, maxScrollXpx)
        .toDouble();
    notifyListeners();
  }

  void zoomHorizontalIn() =>
      setPixelsPerTick(_pixelsPerTick * PianoRollLayoutConstants.zoomMultiplierStep);

  void zoomHorizontalOut() =>
      setPixelsPerTick(_pixelsPerTick / PianoRollLayoutConstants.zoomMultiplierStep);

  void setRowHeightPx(double value) {
    final clamped = value
        .clamp(
          PianoRollLayoutConstants.minRowHeightPx,
          PianoRollLayoutConstants.maxRowHeightPx,
        )
        .toDouble();
    if (clamped == _rowHeightPx) {
      return;
    }
    _rowHeightPx = clamped;
    _scrollYpx = _scrollYpx
        .clamp(PianoRollLayoutConstants.minScrollPx, maxScrollYpx)
        .toDouble();
    notifyListeners();
  }

  void zoomVerticalIn() =>
      setRowHeightPx(_rowHeightPx * PianoRollLayoutConstants.zoomMultiplierStep);

  void zoomVerticalOut() =>
      setRowHeightPx(_rowHeightPx / PianoRollLayoutConstants.zoomMultiplierStep);

  void setToolMode(PianoRollToolMode mode) {
    if (_activeTool == mode) {
      return;
    }
    _resetTransientGesture();
    _activeTool = mode;
    notifyListeners();
  }

  void setDefaultVelocity(int velocity) {
    final clamped = velocity.clamp(
      MuseConstants.minMidiVelocity,
      MuseConstants.maxMidiVelocity,
    );
    if (clamped == _defaultVelocity) {
      return;
    }
    _defaultVelocity = clamped;
    notifyListeners();
  }

  void setSelectedSnapTicksLocal(int ticks) {
    if (!MusePresentationConstants.supportedSubdivisionTicks.contains(ticks)) {
      throw ArgumentError.value(
        ticks,
        'ticks',
        'Must belong to MusePresentationConstants.supportedSubdivisionTicks',
      );
    }
    if (_selectedSnapTicks == ticks) {
      return;
    }
    _selectedSnapTicks = ticks;
    notifyListeners();
  }

  Future<Result<ScoreWorkspaceState>> updateProjectSnapTicks(int ticks) async {
    setSelectedSnapTicksLocal(ticks);
    return _workspaceShellController.updateProjectSettings(gridSnapTicks: ticks);
  }

  void selectNotes(Set<NoteId> noteIds) {
    if (setEquals(_selectedNoteIds, noteIds)) {
      return;
    }
    _selectedNoteIds = Set<NoteId>.unmodifiable(noteIds);
    notifyListeners();
  }

  void dismissError() {
    if (_lastError == null) {
      return;
    }
    _lastError = null;
    notifyListeners();
  }

  /// Begins a pointer interaction in viewport-local pixel coordinates on the grid.
  void onCanvasPointerDown(
    Offset localViewportPos, {
    int buttons = 0,
    bool isPanModifierPressed = false,
  }) {
    final ws = activeWorkspace;
    final partId = activePartId;
    final calculator = _workspaceShellController
        .buildTimelineCalculatorForActiveWorkspace();
    if (ws == null || partId == null || calculator == null) {
      return;
    }

    _resetTransientGesture();

    if (_activeTool == PianoRollToolMode.pan ||
        (buttons & kMiddleMouseButton) != 0 ||
        isPanModifierPressed) {
      _dragKind = _DragGestureKind.pan;
      _panLastViewportPos = localViewportPos;
      notifyListeners();
      return;
    }

    final timingMode = ws.aggregate.project.playbackTimingMode;
    final slice = computeVisibleSlice();

    if (_activeTool == PianoRollToolMode.erase) {
      final hit = _hitTestNote(localViewportPos, slice.visibleNotes, timingMode);
      if (hit != null) {
        unawaited(_deleteNoteIds(<NoteId>[hit.note.noteId]));
      }
      return;
    }

    if (_activeTool == PianoRollToolMode.draw) {
      final rawTick = screenXToTick(localViewportPos.dx);
      final snappedTick = calculator.quantizeTick(
        rawTick,
        snapSubdivisionTicks: Tick(_selectedSnapTicks),
      );
      final pitch = screenYToPitchMidi(localViewportPos.dy);
      _dragKind = _DragGestureKind.drawNote;
      _dragAnchorTick = snappedTick;
      _dragAnchorPitchMidi = pitch;
      _dragPreviews = <PianoRollDragNotePreview>[
        PianoRollDragNotePreview(
          noteId: null,
          startTick: snappedTick,
          durationTicks: _selectedSnapTicks,
          pitchMidi: pitch,
          velocity: _defaultVelocity,
          isNewNote: true,
        ),
      ];
      _switchAuditionPitch(partId: partId, nextPitchMidi: pitch);
      notifyListeners();
      return;
    }

    // Select mode: hit-test visible notes (prefer resize handle on trailing edge).
    final hit = _hitTestNote(localViewportPos, slice.visibleNotes, timingMode);
    if (hit == null) {
      _selectedNoteIds = const <NoteId>{};
      _dragKind = _DragGestureKind.marquee;
      _marqueeStartViewportPx = localViewportPos;
      _marqueeRectViewportPx = Rect.fromPoints(localViewportPos, localViewportPos);
      notifyListeners();
      return;
    }

    if (hit.isResizeHandle) {
      _selectedNoteIds = Set<NoteId>.unmodifiable(<NoteId>{hit.note.noteId});
      _dragKind = _DragGestureKind.resizeNote;
      _resizeOriginalNote = hit.note;
      final noteStart = _noteStartTick(hit.note, timingMode);
      final noteDur = _noteDurationTicks(hit.note, timingMode);
      _dragPreviews = <PianoRollDragNotePreview>[
        PianoRollDragNotePreview(
          noteId: hit.note.noteId,
          startTick: noteStart,
          durationTicks: noteDur,
          pitchMidi: hit.note.pitchMidi,
          velocity: hit.note.velocity,
          isNewNote: false,
        ),
      ];
      notifyListeners();
      return;
    }

    final movingIds = _selectedNoteIds.contains(hit.note.noteId)
        ? _selectedNoteIds
        : <NoteId>{hit.note.noteId};
    _selectedNoteIds = Set<NoteId>.unmodifiable(movingIds);
    final movingNotes = slice.visibleNotes
        .where((n) => movingIds.contains(n.noteId))
        .toList(growable: false);
    if (movingNotes.isEmpty) {
      return;
    }
    _dragKind = _DragGestureKind.moveNotes;
    _dragAnchorTick = screenXToTick(localViewportPos.dx);
    _dragAnchorPitchMidi = screenYToPitchMidi(localViewportPos.dy);
    _dragOriginalNotes = movingNotes;
    _dragPreviews = <PianoRollDragNotePreview>[
      for (final n in movingNotes)
        PianoRollDragNotePreview(
          noteId: n.noteId,
          startTick: _noteStartTick(n, timingMode),
          durationTicks: _noteDurationTicks(n, timingMode),
          pitchMidi: n.pitchMidi,
          velocity: n.velocity,
          isNewNote: false,
        ),
    ];
    _switchAuditionPitch(partId: partId, nextPitchMidi: hit.note.pitchMidi);
    notifyListeners();
  }

  /// Updates the ephemeral drag preview without writing to SQLite until pointer-up.
  void onCanvasPointerMove(Offset localViewportPos) {
    if (_dragKind == _DragGestureKind.none) {
      return;
    }
    final ws = activeWorkspace;
    final partId = activePartId;
    final calculator = _workspaceShellController
        .buildTimelineCalculatorForActiveWorkspace();
    if (ws == null || partId == null || calculator == null) {
      return;
    }
    final timingMode = ws.aggregate.project.playbackTimingMode;

    switch (_dragKind) {
      case _DragGestureKind.drawNote:
        final currentTick = screenXToTick(localViewportPos.dx);
        final snappedEnd = calculator.quantizeTick(
          currentTick,
          snapSubdivisionTicks: Tick(_selectedSnapTicks),
        );
        final durationTicks = math.max(
          _selectedSnapTicks,
          snappedEnd.value - _dragAnchorTick.value,
        );
        final pitch = screenYToPitchMidi(localViewportPos.dy);
        _dragPreviews = <PianoRollDragNotePreview>[
          PianoRollDragNotePreview(
            noteId: null,
            startTick: _dragAnchorTick,
            durationTicks: durationTicks,
            pitchMidi: pitch,
            velocity: _defaultVelocity,
            isNewNote: true,
          ),
        ];
        _switchAuditionPitch(partId: partId, nextPitchMidi: pitch);
        notifyListeners();
      case _DragGestureKind.resizeNote:
        final orig = _resizeOriginalNote;
        if (orig == null) return;
        final origStart = _noteStartTick(orig, timingMode);
        final pointerTick = screenXToTick(localViewportPos.dx);
        final snappedEnd = calculator.quantizeTick(
          pointerTick,
          snapSubdivisionTicks: Tick(_selectedSnapTicks),
        );
        final nextDuration = math.max(
          _selectedSnapTicks,
          math.max(
            PianoRollLayoutConstants.minEditableDurationTicks,
            snappedEnd.value - origStart.value,
          ),
        );
        _dragPreviews = <PianoRollDragNotePreview>[
          PianoRollDragNotePreview(
            noteId: orig.noteId,
            startTick: origStart,
            durationTicks: nextDuration,
            pitchMidi: orig.pitchMidi,
            velocity: orig.velocity,
            isNewNote: false,
          ),
        ];
        notifyListeners();
      case _DragGestureKind.moveNotes:
        final pointerTick = screenXToTick(localViewportPos.dx);
        final rawDeltaTicks = pointerTick.value - _dragAnchorTick.value;
        final snappedDeltaTicks = calculator
            .quantizeTick(
              Tick(rawDeltaTicks.abs()),
              snapSubdivisionTicks: Tick(_selectedSnapTicks),
            )
            .value *
            (rawDeltaTicks < 0 ? -1 : 1);
        final pitchDelta =
            screenYToPitchMidi(localViewportPos.dy) - _dragAnchorPitchMidi;

        var clampedTickDelta = snappedDeltaTicks;
        for (final orig in _dragOriginalNotes) {
          final start = _noteStartTick(orig, timingMode).value;
          if (start + clampedTickDelta < 0) {
            clampedTickDelta = -start;
          }
        }

        final previews = <PianoRollDragNotePreview>[];
        for (final orig in _dragOriginalNotes) {
          final nextStart = Tick(
            math.max(0, _noteStartTick(orig, timingMode).value + clampedTickDelta),
          );
          final nextPitch = (orig.pitchMidi + pitchDelta).clamp(
            PianoRollLayoutConstants.minPitchMidi,
            PianoRollLayoutConstants.maxPitchMidi,
          );
          previews.add(
            PianoRollDragNotePreview(
              noteId: orig.noteId,
              startTick: nextStart,
              durationTicks: _noteDurationTicks(orig, timingMode),
              pitchMidi: nextPitch,
              velocity: orig.velocity,
              isNewNote: false,
            ),
          );
        }
        _dragPreviews = previews;
        if (previews.isNotEmpty) {
          _switchAuditionPitch(
            partId: partId,
            nextPitchMidi: previews.first.pitchMidi,
          );
        }
        notifyListeners();
      case _DragGestureKind.marquee:
        final start = _marqueeStartViewportPx;
        if (start == null) return;
        _marqueeRectViewportPx = Rect.fromPoints(start, localViewportPos);
        notifyListeners();
      case _DragGestureKind.pan:
        final last = _panLastViewportPos;
        if (last == null) return;
        final delta = localViewportPos - last;
        _panLastViewportPos = localViewportPos;
        panBy(dxPx: -delta.dx, dyPx: -delta.dy);
      case _DragGestureKind.none:
        break;
    }
  }

  /// Finalizes an ongoing pointer interaction and commits a single L4 `ScoreCommand`.
  Future<Result<ScoreWorkspaceState>?> onCanvasPointerUp() async {
    _releaseAuditionPitch();
    final kind = _dragKind;
    if (kind == _DragGestureKind.none) {
      return null;
    }

    final ws = activeWorkspace;
    final partId = activePartId;
    if (ws == null || partId == null) {
      _resetTransientGesture();
      notifyListeners();
      return null;
    }

    final timingMode = ws.aggregate.project.playbackTimingMode;

    switch (kind) {
      case _DragGestureKind.drawNote:
        final preview = _dragPreviews.firstOrNull;
        _resetTransientGesture();
        if (preview == null) {
          notifyListeners();
          return null;
        }
        final targetPart = ws.aggregate.parts
            .where((p) => p.partId == partId)
            .firstOrNull;
        if (targetPart == null) {
          notifyListeners();
          return null;
        }
        final crispPitch = Pitch.fromMidi(preview.pitchMidi);
        final noteId = NoteId(_uuidV7Generator());
        final newNote = TimelineNote(
          noteId: noteId,
          projectId: ws.aggregate.project.projectId,
          partId: targetPart.partId,
          staffNumber: MusePresentationConstants.singleStaffNumber,
          voiceNumber: MusePresentationConstants.minVoiceNumber,
          pitchMidi: preview.pitchMidi,
          enharmonicStep: _fromCrispStep(crispPitch.step),
          enharmonicAlter: crispPitch.alter,
          rawStartTick: preview.startTick,
          rawDurationTicks: math.max(
            PianoRollLayoutConstants.minEditableDurationTicks,
            preview.durationTicks,
          ),
          quantizedStartTick: preview.startTick,
          quantizedDurationTicks: math.max(
            PianoRollLayoutConstants.minEditableDurationTicks,
            preview.durationTicks,
          ),
          velocity: preview.velocity,
          updatedAtMs: _nowEpochMs(),
        );
        _selectedNoteIds = Set<NoteId>.unmodifiable(<NoteId>{noteId});
        final result = await _workspaceShellController.executeScoreCommand(
          InsertNotesCommand(<TimelineNote>[newNote]),
        );
        if (result case Err<ScoreWorkspaceState>(:final error)) {
          _lastError = error;
        } else {
          _lastError = null;
        }
        notifyListeners();
        return result;

      case _DragGestureKind.resizeNote:
        final orig = _resizeOriginalNote;
        final preview = _dragPreviews.firstOrNull;
        _resetTransientGesture();
        if (orig == null || preview == null) {
          notifyListeners();
          return null;
        }
        final origDur = _noteDurationTicks(orig, timingMode);
        if (preview.durationTicks == origDur) {
          notifyListeners();
          return null;
        }
        final updated = _buildUpdatedNoteFromGeometry(
          orig: orig,
          timingMode: timingMode,
          nextStartTick: _noteStartTick(orig, timingMode),
          nextDurationTicks: preview.durationTicks,
          nextPitchMidi: orig.pitchMidi,
          updatedAtMs: _nowEpochMs(),
        );
        final result = await _workspaceShellController.executeScoreCommand(
          UpdateNotesCommand(<TimelineNote>[updated]),
        );
        if (result case Err<ScoreWorkspaceState>(:final error)) {
          _lastError = error;
        } else {
          _lastError = null;
        }
        notifyListeners();
        return result;

      case _DragGestureKind.moveNotes:
        final origById = <NoteId, TimelineNote>{
          for (final n in _dragOriginalNotes) n.noteId: n,
        };
        final previews = List<PianoRollDragNotePreview>.from(_dragPreviews);
        _resetTransientGesture();
        final now = _nowEpochMs();
        final updatedNotes = <TimelineNote>[];
        for (final preview in previews) {
          final id = preview.noteId;
          if (id == null) continue;
          final orig = origById[id];
          if (orig == null) continue;
          final origStart = _noteStartTick(orig, timingMode);
          if (preview.startTick == origStart &&
              preview.pitchMidi == orig.pitchMidi) {
            continue;
          }
          updatedNotes.add(
            _buildUpdatedNoteFromGeometry(
              orig: orig,
              timingMode: timingMode,
              nextStartTick: preview.startTick,
              nextDurationTicks: preview.durationTicks,
              nextPitchMidi: preview.pitchMidi,
              updatedAtMs: now,
            ),
          );
        }
        if (updatedNotes.isEmpty) {
          notifyListeners();
          return null;
        }
        final result = await _workspaceShellController.executeScoreCommand(
          UpdateNotesCommand(updatedNotes),
        );
        if (result case Err<ScoreWorkspaceState>(:final error)) {
          _lastError = error;
        } else {
          _lastError = null;
        }
        notifyListeners();
        return result;

      case _DragGestureKind.marquee:
        final rect = _marqueeRectViewportPx;
        _resetTransientGesture();
        if (rect != null) {
          final slice = computeVisibleSlice();
          final matched = <NoteId>{};
          for (final note in slice.visibleNotes) {
            final noteRect = _noteViewportRect(note, timingMode);
            if (rect.overlaps(noteRect)) {
              matched.add(note.noteId);
            }
          }
          _selectedNoteIds = Set<NoteId>.unmodifiable(matched);
        }
        notifyListeners();
        return null;

      case _DragGestureKind.pan:
        _resetTransientGesture();
        notifyListeners();
        return null;

      case _DragGestureKind.none:
        return null;
    }
  }

  void onCanvasPointerCancel() {
    _releaseAuditionPitch();
    if (_dragKind == _DragGestureKind.none) {
      return;
    }
    _resetTransientGesture();
    notifyListeners();
  }

  Future<Result<ScoreWorkspaceState>?> deleteSelectedNotes() async {
    if (_selectedNoteIds.isEmpty) {
      return null;
    }
    return _deleteNoteIds(List<NoteId>.unmodifiable(_selectedNoteIds));
  }

  Future<Result<ScoreWorkspaceState>?> updateNotesVelocity({
    required NoteId noteId,
    required int velocity,
  }) async {
    final ws = activeWorkspace;
    if (ws == null) {
      return null;
    }
    final targetIds = _selectedNoteIds.contains(noteId)
        ? _selectedNoteIds
        : <NoteId>{noteId};
    final clampedVel = velocity.clamp(
      MuseConstants.minMidiVelocity,
      MuseConstants.maxMidiVelocity,
    );
    final now = _nowEpochMs();
    final updated = <TimelineNote>[
      for (final note in ws.aggregate.notes)
        if (targetIds.contains(note.noteId))
          TimelineNote(
            noteId: note.noteId,
            projectId: note.projectId,
            partId: note.partId,
            staffNumber: note.staffNumber,
            voiceNumber: note.voiceNumber,
            pitchMidi: note.pitchMidi,
            enharmonicStep: note.enharmonicStep,
            enharmonicAlter: note.enharmonicAlter,
            rawStartTick: note.rawStartTick,
            rawDurationTicks: note.rawDurationTicks,
            quantizedStartTick: note.quantizedStartTick,
            quantizedDurationTicks: note.quantizedDurationTicks,
            velocity: clampedVel,
            updatedAtMs: now,
          ),
    ];
    if (updated.isEmpty) {
      return null;
    }
    final result = await _workspaceShellController.executeScoreCommand(
      UpdateNotesCommand(updated),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      _lastError = error;
      notifyListeners();
    } else {
      _lastError = null;
    }
    return result;
  }

  void auditionKeyGutterPitchDown(int pitchMidi) {
    final partId = activePartId;
    if (partId == null) return;
    _switchAuditionPitch(partId: partId, nextPitchMidi: pitchMidi);
  }

  void auditionKeyGutterPitchMove(int pitchMidi) {
    final partId = activePartId;
    if (partId == null) return;
    _switchAuditionPitch(partId: partId, nextPitchMidi: pitchMidi);
  }

  void auditionKeyGutterPitchUp() => _releaseAuditionPitch();

  Future<Result<ScoreWorkspaceState>> _deleteNoteIds(
    List<NoteId> noteIds,
  ) async {
    final result = await _workspaceShellController.executeScoreCommand(
      DeleteNotesCommand(noteIds),
    );
    if (result case Err<ScoreWorkspaceState>(:final error)) {
      _lastError = error;
    } else {
      _selectedNoteIds = Set<NoteId>.unmodifiable(
        _selectedNoteIds.where((id) => !noteIds.contains(id)),
      );
      _lastError = null;
    }
    notifyListeners();
    return result;
  }

  Tick _computeTakeDurationTicks(
    AudioTakeEntity take,
    ITempoTimelineCalculator calculator,
  ) {
    final takeStartFrame = calculator.tickToSampleFrame(
      take.startTick,
      sampleRate: take.sampleRate,
    );
    final takeEndTick = calculator.sampleFrameToTick(
      SampleFrame(takeStartFrame.value + take.durationFrames),
      sampleRate: take.sampleRate,
    );
    return Tick(math.max(0, takeEndTick.value - take.startTick.value));
  }

  ({TimelineNote note, bool isResizeHandle})? _hitTestNote(
    Offset localViewportPos,
    List<TimelineNote> visibleNotes,
    PlaybackTimingMode timingMode,
  ) {
    for (final note in visibleNotes.reversed) {
      final rect = _noteViewportRect(note, timingMode);
      if (rect.contains(localViewportPos)) {
        final handleStart = math.max(
          rect.left,
          rect.right - PianoRollLayoutConstants.noteResizeHandleWidthPx,
        );
        final isResize =
            localViewportPos.dx >= handleStart &&
            rect.width > PianoRollLayoutConstants.noteResizeHandleWidthPx;
        return (note: note, isResizeHandle: isResize);
      }
    }
    return null;
  }

  Rect _noteViewportRect(TimelineNote note, PlaybackTimingMode timingMode) {
    final startTick = _noteStartTick(note, timingMode).value;
    final durationTicks = _noteDurationTicks(note, timingMode);
    final left = startTick * _pixelsPerTick - _scrollXpx;
    final rawWidth = durationTicks * _pixelsPerTick;
    final width = math.max(
      PianoRollLayoutConstants.minNoteRectWidthPx,
      rawWidth,
    );
    final top =
        (PianoRollLayoutConstants.maxPitchMidi - note.pitchMidi) * _rowHeightPx -
        _scrollYpx;
    return Rect.fromLTWH(left, top, width, _rowHeightPx);
  }

  static Tick _noteStartTick(TimelineNote note, PlaybackTimingMode mode) =>
      mode == PlaybackTimingMode.raw
      ? note.rawStartTick
      : note.quantizedStartTick;

  static int _noteDurationTicks(TimelineNote note, PlaybackTimingMode mode) =>
      mode == PlaybackTimingMode.raw
      ? note.rawDurationTicks
      : note.quantizedDurationTicks;

  static TimelineNote _buildUpdatedNoteFromGeometry({
    required TimelineNote orig,
    required PlaybackTimingMode timingMode,
    required Tick nextStartTick,
    required int nextDurationTicks,
    required int nextPitchMidi,
    required int updatedAtMs,
  }) {
    final safeDuration = math.max(
      PianoRollLayoutConstants.minEditableDurationTicks,
      nextDurationTicks,
    );
    final pitchChanged = nextPitchMidi != orig.pitchMidi;
    final EnharmonicStep step;
    final int alter;
    if (pitchChanged) {
      final crispPitch = Pitch.fromMidi(nextPitchMidi);
      step = _fromCrispStep(crispPitch.step);
      alter = crispPitch.alter;
    } else {
      step = orig.enharmonicStep;
      alter = orig.enharmonicAlter;
    }

    final int rawStart;
    final int rawDur;
    final int quantStart;
    final int quantDur;
    if (timingMode == PlaybackTimingMode.raw) {
      final startDelta = nextStartTick.value - orig.rawStartTick.value;
      final durDelta = safeDuration - orig.rawDurationTicks;
      rawStart = nextStartTick.value;
      rawDur = safeDuration;
      quantStart = math.max(0, orig.quantizedStartTick.value + startDelta);
      quantDur = math.max(
        PianoRollLayoutConstants.minEditableDurationTicks,
        orig.quantizedDurationTicks + durDelta,
      );
    } else {
      final startDelta = nextStartTick.value - orig.quantizedStartTick.value;
      final durDelta = safeDuration - orig.quantizedDurationTicks;
      quantStart = nextStartTick.value;
      quantDur = safeDuration;
      rawStart = math.max(0, orig.rawStartTick.value + startDelta);
      rawDur = math.max(
        PianoRollLayoutConstants.minEditableDurationTicks,
        orig.rawDurationTicks + durDelta,
      );
    }

    return TimelineNote(
      noteId: orig.noteId,
      projectId: orig.projectId,
      partId: orig.partId,
      staffNumber: orig.staffNumber,
      voiceNumber: orig.voiceNumber,
      pitchMidi: nextPitchMidi,
      enharmonicStep: step,
      enharmonicAlter: alter,
      rawStartTick: Tick(rawStart),
      rawDurationTicks: rawDur,
      quantizedStartTick: Tick(quantStart),
      quantizedDurationTicks: quantDur,
      velocity: orig.velocity,
      updatedAtMs: updatedAtMs,
    );
  }

  void _switchAuditionPitch({
    required PartId partId,
    required int nextPitchMidi,
  }) {
    final clamped = nextPitchMidi.clamp(
      PianoRollLayoutConstants.minPitchMidi,
      PianoRollLayoutConstants.maxPitchMidi,
    );
    if (_auditionedPartId == partId && _auditionedPitchMidi == clamped) {
      return;
    }
    _releaseAuditionPitch();
    _auditionedPartId = partId;
    _auditionedPitchMidi = clamped;
    _playbackCoordinator.auditionNote(
      partId: partId,
      pitchMidi: clamped,
      velocity: _defaultVelocity,
      isNoteOn: true,
    );
  }

  void _releaseAuditionPitch() {
    final partId = _auditionedPartId;
    final pitch = _auditionedPitchMidi;
    if (partId == null || pitch == null) {
      return;
    }
    _auditionedPartId = null;
    _auditionedPitchMidi = null;
    _playbackCoordinator.auditionNote(
      partId: partId,
      pitchMidi: pitch,
      velocity: LookaheadPlaybackConstants.noteOffReleaseVelocity,
      isNoteOn: false,
    );
  }

  void _resetTransientGesture() {
    _dragKind = _DragGestureKind.none;
    _dragPreviews = const <PianoRollDragNotePreview>[];
    _marqueeRectViewportPx = null;
    _marqueeStartViewportPx = null;
    _panLastViewportPos = null;
    _dragOriginalNotes = const <TimelineNote>[];
    _resizeOriginalNote = null;
  }

  void _handleWorkspaceChange() {
    _syncFromWorkspace(initial: false);
    notifyListeners();
  }

  void _syncFromWorkspace({required bool initial}) {
    final ws = activeWorkspace;
    if (ws == null) {
      _lastSyncedProjectId = null;
      _lastSyncedProjectGridSnapTicks = null;
      _lastSyncedSelectedPartId = null;
      _selectedNoteIds = const <NoteId>{};
      _scrollXpx = PianoRollLayoutConstants.minScrollPx;
      _scrollYpx = PianoRollLayoutConstants.minScrollPx;
      _hasInitializedScrollY = false;
      _resetTransientGesture();
      return;
    }

    final projectId = ws.aggregate.project.projectId;
    final projectSnap = ws.aggregate.project.gridSnapTicks;
    final currentPartId = activePartId;

    final projectChanged = _lastSyncedProjectId != projectId;
    final snapChangedOnProject = _lastSyncedProjectGridSnapTicks != projectSnap;
    final partChanged = !initial && _lastSyncedSelectedPartId != currentPartId;

    if (projectChanged || snapChangedOnProject) {
      if (MusePresentationConstants.supportedSubdivisionTicks.contains(
        projectSnap,
      )) {
        _selectedSnapTicks = projectSnap;
      }
      _lastSyncedProjectId = projectId;
      _lastSyncedProjectGridSnapTicks = projectSnap;
    }

    if (projectChanged || partChanged) {
      _selectedNoteIds = const <NoteId>{};
      _resetTransientGesture();
    } else if (_selectedNoteIds.isNotEmpty) {
      final validIds = <NoteId>{for (final n in ws.aggregate.notes) n.noteId};
      _selectedNoteIds = Set<NoteId>.unmodifiable(
        _selectedNoteIds.where(validIds.contains),
      );
    }

    if (projectChanged && !initial) {
      _scrollXpx = PianoRollLayoutConstants.minScrollPx;
      if (_hasInitializedScrollY) {
        _scrollYpx = _centeredScrollYForPitch(
          PianoRollLayoutConstants.initialScrollCenterPitchMidi,
        );
      }
    } else {
      _scrollXpx = _scrollXpx
          .clamp(PianoRollLayoutConstants.minScrollPx, maxScrollXpx)
          .toDouble();
      _scrollYpx = _scrollYpx
          .clamp(PianoRollLayoutConstants.minScrollPx, maxScrollYpx)
          .toDouble();
    }

    _lastSyncedSelectedPartId = currentPartId;
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

  @override
  void dispose() {
    _isDisposed = true;
    _releaseAuditionPitch();
    _workspaceShellController.removeListener(_handleWorkspaceChange);
    super.dispose();
  }

  bool get isDisposed => _isDisposed;
}
