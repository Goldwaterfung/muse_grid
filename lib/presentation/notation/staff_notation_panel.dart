/// Interactive `crisp_notation` staff engraving panel, toolbar, and event inspector.
library;

import 'dart:async';

import 'package:crisp_notation/crisp_notation.dart'
    show MusicFonts, RenderStaffSystemView, StaffSystemView;
import 'package:flutter/gestures.dart';
import 'package:material_ui/material_ui.dart';

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import '../../domain/notation/crisp_score_mapper.dart';
import '../controllers/transport_and_telemetry_controller.dart';
import '../controllers/workspace_shell_controller.dart';
import '../theme/muse_presentation_constants.dart';
import 'staff_notation_view_controller.dart';
import 'staff_playhead_and_caret_painter.dart';

/// Complete Layer 5 Staff Notation workspace panel featuring fail-closed SMuFL
/// font verification, multi-voice alignment, `RepaintBoundary` playhead/caret overlay,
/// engraving toolbar, and "Measure & Score Events" inspector.
final class StaffNotationPanel extends StatefulWidget {
  final StaffNotationViewController controller;
  final WorkspaceShellController workspaceController;
  final TransportAndTelemetryController transportController;
  final VoidCallback? onPlayheadPaintForTest;

  const StaffNotationPanel({
    super.key,
    required this.controller,
    required this.workspaceController,
    required this.transportController,
    this.onPlayheadPaintForTest,
  });

  @override
  State<StaffNotationPanel> createState() => _StaffNotationPanelState();
}

final class _StaffNotationPanelState extends State<StaffNotationPanel> {
  final ScrollController _horizontalScroll = ScrollController();
  final ScrollController _verticalScroll = ScrollController();

  int _entryPitchMidi = NotationViewConstants.middleCMidiPitch;
  Offset? _pointerDownPosition;
  bool _elementTapHandled = false;

  @override
  void dispose() {
    _horizontalScroll.dispose();
    _verticalScroll.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        widget.workspaceController,
      ]),
      builder: (context, _) {
        final ws = widget.controller.activeWorkspace;
        if (ws == null) {
          return const Center(child: Text('No project workspace is open.'));
        }

        final fontMeta = MusicFonts.metadataOrNull(
          MusePresentationConstants.defaultNotationTheme.musicFont,
        );
        if (fontMeta == null) {
          return Container(
            key: const Key('notation_font_missing_error_card'),
            padding: const EdgeInsets.all(
              NotationViewConstants.errorBannerPaddingPx,
            ),
            decoration: BoxDecoration(
              color: NotationViewConstants.errorBannerColor,
              border: Border.all(
                color: NotationViewConstants.errorBannerBorderColor,
              ),
            ),
            child: const Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Bravura SMuFL font metadata is not loaded.',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: NotationViewConstants.errorBannerTextColor,
                  ),
                ),
                SizedBox(height: MusePresentationConstants.standardControlGapPx),
                Text(
                  'Staff engraving cannot render safely without verified SMuFL metrics.',
                  style: TextStyle(
                    color: NotationViewConstants.errorBannerTextColor,
                  ),
                ),
              ],
            ),
          );
        }

        final layout = widget.controller.ensureCachedLayout();
        final staffSpace =
            NotationViewConstants.baseStaffSpacePx * widget.controller.zoomScale;
        final canvasWidth =
            layout == null
            ? staffSpace * NotationViewConstants.notationViewportPaddingPx
            : (layout.width + RenderStaffSystemView.leftInset) * staffSpace +
                  NotationViewConstants.notationViewportPaddingPx;
        final canvasHeight =
            layout == null
            ? staffSpace * NotationViewConstants.notationViewportPaddingPx
            : layout.height * staffSpace +
                  NotationViewConstants.notationViewportPaddingPx;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _NotationToolbar(
              controller: widget.controller,
              workspaceController: widget.workspaceController,
              transportController: widget.transportController,
              entryPitchMidi: _entryPitchMidi,
              onChangeEntryPitch: (nextPitch) {
                setState(() {
                  _entryPitchMidi = nextPitch.clamp(
                    MuseConstants.minMidiPitch,
                    MuseConstants.maxMidiPitch,
                  );
                });
              },
              onOpenClefDialog: () => _showClefDialog(context),
              onOpenKeySigDialog: () => _showKeySignatureDialog(context),
              onOpenTimeSigDialog: () => _showTimeSignatureDialog(context),
              onOpenTempoDialog: () => _showTempoDialog(context),
            ),
            if (widget.controller.lastError != null)
              _NotationErrorBanner(
                error: widget.controller.lastError!,
                onDismiss: widget.controller.dismissError,
              ),
            Expanded(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Expanded(
                    child: Container(
                      decoration: BoxDecoration(
                        color: NotationViewConstants.notationSurfaceColor,
                        border: Border.all(
                          color: NotationViewConstants.notationBorderColor,
                        ),
                      ),
                      child: SingleChildScrollView(
                        controller: _verticalScroll,
                        child: SingleChildScrollView(
                          controller: _horizontalScroll,
                          scrollDirection: Axis.horizontal,
                          child: Padding(
                            padding: const EdgeInsets.all(
                              NotationViewConstants.notationViewportPaddingPx,
                            ),
                            child: SizedBox(
                              width: canvasWidth,
                              height: canvasHeight,
                              child: Stack(
                                children: <Widget>[
                                  RepaintBoundary(
                                    child: Listener(
                                      behavior: HitTestBehavior.translucent,
                                      onPointerDown: (event) {
                                        _pointerDownPosition = event.position;
                                        _elementTapHandled = false;
                                      },
                                      onPointerUp: (event) {
                                        final down = _pointerDownPosition;
                                        _pointerDownPosition = null;
                                        if (down == null ||
                                            (event.position - down).distance >
                                                kTouchSlop) {
                                          return;
                                        }
                                        final localPos = event.localPosition;
                                        scheduleMicrotask(() {
                                          if (!_elementTapHandled && mounted) {
                                            widget.controller.onStaffCanvasTapped(
                                              localPos,
                                            );
                                          }
                                        });
                                      },
                                      child: StaffSystemView(
                                        system: ws.renderSnapshot.crispScoreModel,
                                        theme: MusePresentationConstants
                                            .defaultNotationTheme,
                                        staffSpace: staffSpace,
                                        staffGap:
                                            NotationViewConstants.staffGapSpaces,
                                        gridAlign: !widget
                                            .controller
                                            .hasMultiVoiceMeasures,
                                        hideEmptyStaves:
                                            widget.controller.hideEmptyStaves,
                                        highlightedIds: widget
                                            .controller
                                            .highlightedCrispElementIds,
                                        onElementTap: (elementId) {
                                          _elementTapHandled = true;
                                          unawaited(
                                            widget.controller
                                                .onCrispElementTapped(elementId),
                                          );
                                        },
                                      ),
                                    ),
                                  ),
                                  Positioned.fill(
                                    child: RepaintBoundary(
                                      child: IgnorePointer(
                                        child: CustomPaint(
                                          key: const Key(
                                            'staff_playhead_overlay',
                                          ),
                                          painter: StaffPlayheadAndCaretPainter(
                                            playheadTickListenable: widget
                                                .transportController
                                                .playheadTick,
                                            staffController: widget.controller,
                                            calculatorProvider: widget
                                                .workspaceController
                                                .buildTimelineCalculatorForActiveWorkspace,
                                            onPaintCallback:
                                                widget.onPlayheadPaintForTest,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  SizedBox(
                    width: NotationViewConstants.inspectorPanelWidthPx,
                    child: _NotationInspectorControls(
                      controller: widget.controller,
                      aggregate: ws.aggregate,
                    ),
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _showClefDialog(BuildContext context) async {
    var sign = ClefSign.G;
    var line = CrispScoreMapperConstants.trebleClefLine;
    var octaveChange = MusePresentationConstants.defaultClefOctaveChange;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Insert Clef at Cursor'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DropdownButton<ClefSign>(
                value: sign,
                items: ClefSign.values
                    .map(
                      (s) => DropdownMenuItem<ClefSign>(
                        value: s,
                        child: Text(s.name),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (next) {
                  if (next != null) {
                    setDialogState(() => sign = next);
                  }
                },
              ),
              DropdownButton<int>(
                value: line,
                items: List<DropdownMenuItem<int>>.generate(
                  NotationViewConstants.maxClefLine,
                  (idx) {
                    final l = NotationViewConstants.minClefLine + idx;
                    return DropdownMenuItem<int>(
                      value: l,
                      child: Text('Line $l'),
                    );
                  },
                ),
                onChanged: (next) {
                  if (next != null) {
                    setDialogState(() => line = next);
                  }
                },
              ),
              DropdownButton<int>(
                value: octaveChange,
                items: <int>[
                  for (
                    var o = NotationViewConstants.minClefOctaveChange;
                    o <= NotationViewConstants.maxClefOctaveChange;
                    o++
                  )
                    o,
                ]
                    .map(
                      (o) => DropdownMenuItem<int>(
                        value: o,
                        child: Text('Octave $o'),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (next) {
                  if (next != null) {
                    setDialogState(() => octaveChange = next);
                  }
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await widget.controller.setClefAtCursor(
        sign: sign,
        line: line,
        octaveChange: octaveChange,
      );
    }
  }

  Future<void> _showKeySignatureDialog(BuildContext context) async {
    var fifths = CrispScoreMapperConstants.defaultKeySignatureFifths;
    var mode = KeyMode.major;
    var globalToScore = true;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('Insert Key Signature at Cursor'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              DropdownButton<int>(
                value: fifths,
                items: <int>[
                  for (
                    var f = NotationViewConstants.minKeySignatureFifths;
                    f <= NotationViewConstants.maxKeySignatureFifths;
                    f++
                  )
                    f,
                ]
                    .map(
                      (f) => DropdownMenuItem<int>(
                        value: f,
                        child: Text('Fifths $f'),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (next) {
                  if (next != null) {
                    setDialogState(() => fifths = next);
                  }
                },
              ),
              DropdownButton<KeyMode>(
                value: mode,
                items: KeyMode.values
                    .map(
                      (m) => DropdownMenuItem<KeyMode>(
                        value: m,
                        child: Text(m.name),
                      ),
                    )
                    .toList(growable: false),
                onChanged: (next) {
                  if (next != null) {
                    setDialogState(() => mode = next);
                  }
                },
              ),
              CheckboxListTile(
                title: const Text('Apply to entire score'),
                value: globalToScore,
                onChanged: (val) {
                  if (val != null) {
                    setDialogState(() => globalToScore = val);
                  }
                },
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Apply'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      await widget.controller.setKeySignatureAtCursor(
        fifths: fifths,
        mode: mode,
        globalToScore: globalToScore,
      );
    }
  }

  Future<void> _showTimeSignatureDialog(BuildContext context) async {
    final result = await showDialog<({int numerator, int denominator})>(
      context: context,
      builder: (_) => const _TimeSignatureDialog(),
    );
    if (result != null) {
      await widget.controller.setTimeSignatureAtCursor(
        numerator: result.numerator,
        denominator: result.denominator,
      );
    }
  }

  Future<void> _showTempoDialog(BuildContext context) async {
    final bpm = await showDialog<int>(
      context: context,
      builder: (_) => const _TempoAtCursorDialog(),
    );
    if (bpm != null) {
      await widget.controller.setTempoAtCursor(bpm: bpm);
    }
  }
}

final class _NotationToolbar extends StatelessWidget {
  final StaffNotationViewController controller;
  final WorkspaceShellController workspaceController;
  final TransportAndTelemetryController transportController;
  final int entryPitchMidi;
  final ValueChanged<int> onChangeEntryPitch;
  final VoidCallback onOpenClefDialog;
  final VoidCallback onOpenKeySigDialog;
  final VoidCallback onOpenTimeSigDialog;
  final VoidCallback onOpenTempoDialog;

  const _NotationToolbar({
    required this.controller,
    required this.workspaceController,
    required this.transportController,
    required this.entryPitchMidi,
    required this.onChangeEntryPitch,
    required this.onOpenClefDialog,
    required this.onOpenKeySigDialog,
    required this.onOpenTimeSigDialog,
    required this.onOpenTempoDialog,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: NotationViewConstants.toolbarHeightPx,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(
          horizontal: MusePresentationConstants.standardControlGapPx,
        ),
        child: Row(
          children: <Widget>[
            DropdownButton<int>(
              key: const Key('notation_duration_dropdown'),
              value: controller.activeDurationTicks,
              items: MusePresentationConstants.supportedSubdivisionTicks
                  .map(
                    (ticks) => DropdownMenuItem<int>(
                      value: ticks,
                      child: Text(_subdivisionLabel(ticks)),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  controller.setActiveDurationTicks(value);
                }
              },
            ),
            const SizedBox(width: MusePresentationConstants.standardControlGapPx),
            DropdownButton<int>(
              key: const Key('notation_voice_dropdown'),
              value: controller.activeVoiceNumber,
              items: <int>[
                for (
                  var v = MusePresentationConstants.minVoiceNumber;
                  v <= MusePresentationConstants.maxVoiceNumber;
                  v++
                )
                  v,
              ]
                  .map(
                    (v) =>
                        DropdownMenuItem<int>(value: v, child: Text('Voice $v')),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  controller.setActiveVoiceNumber(value);
                }
              },
            ),
            const SizedBox(width: MusePresentationConstants.standardControlGapPx),
            FilterChip(
              label: const Text('Chord Select'),
              selected: controller.isChordSelectMode,
              onSelected: controller.setChordSelectMode,
            ),
            const SizedBox(width: MusePresentationConstants.standardControlGapPx),
            FilterChip(
              label: const Text('Quantize Insert'),
              selected: controller.quantizeInsertedNotes,
              onSelected: controller.setQuantizeInsertedNotes,
            ),
            IconButton(
              tooltip: 'Lower entry pitch',
              onPressed: () => onChangeEntryPitch(
                entryPitchMidi + NotationViewConstants.chromaticSemitoneDown,
              ),
              icon: const Icon(Icons.remove),
            ),
            Text('MIDI $entryPitchMidi'),
            IconButton(
              tooltip: 'Raise entry pitch',
              onPressed: () => onChangeEntryPitch(
                entryPitchMidi + NotationViewConstants.chromaticSemitoneUp,
              ),
              icon: const Icon(Icons.add),
            ),
            FilledButton(
              key: const Key('notation_insert_note_button'),
              onPressed: () => unawaited(
                controller.insertNoteAtCursor(pitchMidi: entryPitchMidi),
              ),
              child: const Text('Insert Note'),
            ),
            const SizedBox(width: MusePresentationConstants.standardControlGapPx),
            OutlinedButton(
              onPressed: () => unawaited(controller.deleteSelectedNotes()),
              child: const Text('Delete'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.transposeSelectedNotesChromatic(
                  NotationViewConstants.chromaticSemitoneDown,
                ),
              ),
              child: const Text('-1'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.transposeSelectedNotesChromatic(
                  NotationViewConstants.chromaticSemitoneUp,
                ),
              ),
              child: const Text('+1'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.transposeSelectedNotesChromatic(
                  NotationViewConstants.chromaticOctaveDown,
                ),
              ),
              child: const Text('-12'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.transposeSelectedNotesChromatic(
                  NotationViewConstants.chromaticOctaveUp,
                ),
              ),
              child: const Text('+12'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.respellSelectedWithPreferredAlter(
                  NotationViewConstants.chromaticSemitoneDown,
                ),
              ),
              child: const Text('♭'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.respellSelectedWithPreferredAlter(
                  NotationViewConstants.initialMapTick,
                ),
              ),
              child: const Text('♮'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.respellSelectedWithPreferredAlter(
                  NotationViewConstants.chromaticSemitoneUp,
                ),
              ),
              child: const Text('♯'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.applySpannerToSelectedNotes(type: SpannerType.tie),
              ),
              child: const Text('Tie'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.applySpannerToSelectedNotes(type: SpannerType.slur),
              ),
              child: const Text('Slur'),
            ),
            OutlinedButton(
              onPressed: () => unawaited(
                controller.applySpannerToSelectedNotes(type: SpannerType.beam),
              ),
              child: const Text('Beam'),
            ),
            OutlinedButton(
              onPressed: () =>
                  unawaited(controller.removeAttachedSpannersFromSelection()),
              child: const Text('Clear Spanner'),
            ),
            OutlinedButton(
              onPressed: onOpenClefDialog,
              child: const Text('Clef...'),
            ),
            OutlinedButton(
              onPressed: onOpenKeySigDialog,
              child: const Text('Key...'),
            ),
            OutlinedButton(
              onPressed: onOpenTimeSigDialog,
              child: const Text('Time...'),
            ),
            OutlinedButton(
              onPressed: onOpenTempoDialog,
              child: const Text('Tempo...'),
            ),
            FilterChip(
              label: const Text('Hide Empty Staves'),
              selected: controller.hideEmptyStaves,
              onSelected: controller.setHideEmptyStaves,
            ),
            IconButton(
              key: const Key('notation_zoom_out_button'),
              tooltip: 'Zoom out notation',
              onPressed: controller.zoomOut,
              icon: const Icon(Icons.zoom_out),
            ),
            IconButton(
              key: const Key('notation_zoom_in_button'),
              tooltip: 'Zoom in notation',
              onPressed: controller.zoomIn,
              icon: const Icon(Icons.zoom_in),
            ),
            RepaintBoundary(
              child: SizedBox(
                width: NotationViewConstants.dialogFieldWidthPx,
                child: ValueListenableBuilder<Tick>(
                  key: const Key('notation_bar_beat_status'),
                  valueListenable: transportController.playheadTick,
                  builder: (context, tick, _) {
                    final calc = workspaceController
                        .buildTimelineCalculatorForActiveWorkspace();
                    if (calc == null) {
                      return const Text('Bar -');
                    }
                    final pos = calc.tickToBarBeatTick(tick);
                    return Text(
                      'Bar ${pos.measureNumber} : Beat ${pos.beatIndex + 1} : ${pos.tickInBeat}',
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _subdivisionLabel(int ticks) => switch (ticks) {
    MuseConstants.wholeNoteTicks => '1/1',
    MuseConstants.halfNoteTicks => '1/2',
    MuseConstants.quarterNoteTicks => '1/4',
    MuseConstants.eighthNoteTicks => '1/8',
    MuseConstants.sixteenthNoteTicks => '1/16',
    MuseConstants.thirtySecondNoteTicks => '1/32',
    MuseConstants.sixtyFourthNoteTicks => '1/64',
    MuseConstants.dottedHalfNoteTicks => '1/2.',
    MuseConstants.dottedQuarterNoteTicks => '1/4.',
    MuseConstants.dottedEighthNoteTicks => '1/8.',
    MuseConstants.dottedSixteenthNoteTicks => '1/16.',
    MuseConstants.dottedThirtySecondNoteTicks => '1/32.',
    MuseConstants.tripletHalfNoteTicks => '1/2T',
    MuseConstants.tripletQuarterNoteTicks => '1/4T',
    MuseConstants.tripletEighthNoteTicks => '1/8T',
    MuseConstants.tripletSixteenthNoteTicks => '1/16T',
    MuseConstants.tripletThirtySecondNoteTicks => '1/32T',
    _ => '$ticks ticks',
  };
}

final class _NotationInspectorControls extends StatelessWidget {
  final StaffNotationViewController controller;
  final ProjectWorkspaceAggregate aggregate;

  const _NotationInspectorControls({
    required this.controller,
    required this.aggregate,
  });

  @override
  Widget build(BuildContext context) {
    final sortedTempos = List<TempoEventEntity>.from(aggregate.tempoEvents)
      ..sort((a, b) => a.tick.value.compareTo(b.tick.value));
    final sortedTimeSigs = List<TimeSignatureEventEntity>.from(
      aggregate.timeSignatureEvents,
    )..sort((a, b) => a.tick.value.compareTo(b.tick.value));
    final sortedKeys = List<KeySignatureEventEntity>.from(
      aggregate.keySignatureEvents,
    )..sort((a, b) => a.tick.value.compareTo(b.tick.value));
    final focusedPartId = controller.focusedPartId;
    final focusedClefs = aggregate.clefEvents
        .where((c) => focusedPartId == null || c.partId == focusedPartId)
        .toList()
      ..sort((a, b) => a.tick.value.compareTo(b.tick.value));

    return Card(
      margin: EdgeInsets.zero,
      child: ListView(
        key: const Key('measure_and_score_events_inspector'),
        padding: const EdgeInsets.all(
          MusePresentationConstants.statusBannerPaddingPx,
        ),
        children: <Widget>[
          const Text(
            'Measure & Score Events',
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          Text('Cursor tick: ${controller.cursorTick.value}'),
          const Divider(height: NotationViewConstants.inspectorDividerHeightPx),
          const Text('Tempo Events'),
          for (final t in sortedTempos)
            ListTile(
              dense: true,
              title: Text(
                '${(MusePresentationConstants.microsecondsPerMinute / t.usPerQuarter).round()} BPM @ ${t.tick.value}',
              ),
              subtitle:
                  t.tick.value == NotationViewConstants.initialMapTick
                  ? const Text('Protected initial event')
                  : null,
              trailing: IconButton(
                key: Key('delete_tempo_${t.tempoEventId.value}'),
                tooltip: 'Delete tempo event',
                onPressed: t.tick.value == NotationViewConstants.initialMapTick
                    ? null
                    : () => unawaited(
                        controller.removeTempoEvent(t.tempoEventId),
                      ),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          const Divider(height: NotationViewConstants.inspectorDividerHeightPx),
          const Text('Time Signature Events'),
          for (final ts in sortedTimeSigs)
            ListTile(
              dense: true,
              title: Text('${ts.numerator}/${ts.denominator} @ ${ts.tick.value}'),
              subtitle:
                  ts.tick.value == NotationViewConstants.initialMapTick
                  ? const Text('Protected initial event')
                  : null,
              trailing: IconButton(
                key: Key('delete_timesig_${ts.tsEventId.value}'),
                tooltip: 'Delete time signature',
                onPressed: ts.tick.value == NotationViewConstants.initialMapTick
                    ? null
                    : () => unawaited(
                        controller.removeTimeSignatureEvent(ts.tsEventId),
                      ),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          const Divider(height: NotationViewConstants.inspectorDividerHeightPx),
          const Text('Key Signature Events'),
          for (final k in sortedKeys)
            ListTile(
              dense: true,
              title: Text('Fifths ${k.fifths} ${k.mode.name} @ ${k.tick.value}'),
              trailing: IconButton(
                key: Key('delete_keysig_${k.keyEventId.value}'),
                tooltip: 'Delete key signature',
                onPressed: () => unawaited(
                  controller.removeKeySignatureEvent(k.keyEventId),
                ),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
          const Divider(height: NotationViewConstants.inspectorDividerHeightPx),
          const Text('Part Clef Events'),
          for (final c in focusedClefs)
            ListTile(
              dense: true,
              title: Text(
                '${c.sign.name} line ${c.line} (staff ${c.staffNumber}) @ ${c.tick.value}',
              ),
              trailing: IconButton(
                key: Key('delete_clef_${c.clefEventId.value}'),
                tooltip: 'Delete clef event',
                onPressed: () =>
                    unawaited(controller.removeClefEvent(c.clefEventId)),
                icon: const Icon(Icons.delete_outline),
              ),
            ),
        ],
      ),
    );
  }
}

final class _NotationErrorBanner extends StatelessWidget {
  final MuseError error;
  final VoidCallback onDismiss;

  const _NotationErrorBanner({required this.error, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(
        horizontal: MusePresentationConstants.statusBannerPaddingPx,
        vertical: MusePresentationConstants.standardControlGapPx,
      ),
      color: NotationViewConstants.errorBannerColor,
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              '${error.code.name}: ${error.message}',
              style: const TextStyle(
                color: NotationViewConstants.errorBannerTextColor,
              ),
            ),
          ),
          TextButton(onPressed: onDismiss, child: const Text('Dismiss')),
        ],
      ),
    );
  }
}

final class _TimeSignatureDialog extends StatefulWidget {
  const _TimeSignatureDialog();

  @override
  State<_TimeSignatureDialog> createState() => _TimeSignatureDialogState();
}

final class _TimeSignatureDialogState extends State<_TimeSignatureDialog> {
  late final TextEditingController _numController;
  late final TextEditingController _denController;

  @override
  void initState() {
    super.initState();
    _numController = TextEditingController(
      text: '${MusePresentationConstants.defaultNewProjectTimeSigNum}',
    );
    _denController = TextEditingController(
      text: '${MusePresentationConstants.defaultNewProjectTimeSigDen}',
    );
  }

  @override
  void dispose() {
    _numController.dispose();
    _denController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Insert Time Signature at Cursor'),
      content: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: NotationViewConstants.dialogFieldWidthPx,
            child: TextField(
              controller: _numController,
              decoration: const InputDecoration(labelText: 'Beats'),
              keyboardType: TextInputType.number,
            ),
          ),
          const SizedBox(width: MusePresentationConstants.standardControlGapPx),
          SizedBox(
            width: NotationViewConstants.dialogFieldWidthPx,
            child: TextField(
              controller: _denController,
              decoration: const InputDecoration(labelText: 'Unit'),
              keyboardType: TextInputType.number,
            ),
          ),
        ],
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () {
            final numVal = int.tryParse(_numController.text.trim());
            final denVal = int.tryParse(_denController.text.trim());
            Navigator.of(context).pop(
              numVal != null && denVal != null
                  ? (numerator: numVal, denominator: denVal)
                  : null,
            );
          },
          child: const Text('Apply'),
        ),
      ],
    );
  }
}

final class _TempoAtCursorDialog extends StatefulWidget {
  const _TempoAtCursorDialog();

  @override
  State<_TempoAtCursorDialog> createState() => _TempoAtCursorDialogState();
}

final class _TempoAtCursorDialogState extends State<_TempoAtCursorDialog> {
  late final TextEditingController _bpmController;

  @override
  void initState() {
    super.initState();
    _bpmController = TextEditingController(
      text: '${MusePresentationConstants.defaultNewProjectTempoBpm}',
    );
  }

  @override
  void dispose() {
    _bpmController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Insert Tempo at Cursor'),
      content: TextField(
        controller: _bpmController,
        decoration: const InputDecoration(labelText: 'BPM'),
        keyboardType: TextInputType.number,
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(
            int.tryParse(_bpmController.text.trim()),
          ),
          child: const Text('Apply'),
        ),
      ],
    );
  }
}
