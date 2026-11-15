/// CustomPainters for viewport-culled Piano Roll grid/notes, audio take strip,
/// and RepaintBoundary-isolated 60 Hz playhead + loop bracket overlay.
library;

import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../domain/models/score_models.dart';
import '../controllers/transport_and_telemetry_controller.dart';
import '../theme/muse_presentation_constants.dart';
import 'piano_roll_viewport_controller.dart';

/// Paints ONLY the visible rows (`visibleMinPitchMidi..visibleMaxPitchMidi`),
/// visible dynamic-LOD grid lines, and culled [PianoRollVisibleSlice.visibleNotes].
/// Ignores 60 Hz playhead ticks cleanly.
final class PianoRollGridPainter extends CustomPainter {
  final PianoRollVisibleSlice slice;
  final Set<NoteId> selectedNoteIds;
  final List<PianoRollDragNotePreview> dragPreviews;
  final double pixelsPerTick;
  final double rowHeightPx;
  final double scrollXpx;
  final double scrollYpx;
  final PlaybackTimingMode playbackTimingMode;
  final Rect? marqueeRectViewportPx;
  final VoidCallback? onPaintCallback;

  PianoRollGridPainter({
    required this.slice,
    required this.selectedNoteIds,
    required this.dragPreviews,
    required this.pixelsPerTick,
    required this.rowHeightPx,
    required this.scrollXpx,
    required this.scrollYpx,
    required this.playbackTimingMode,
    this.marqueeRectViewportPx,
    this.onPaintCallback,
  });

  @override
  void paint(Canvas canvas, Size size) {
    onPaintCallback?.call();

    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = PianoRollLayoutConstants.canvasBackgroundColor,
    );

    // 1. Paint visible horizontal pitch rows & C-octave dividers.
    final lightPaint = Paint()
      ..color = PianoRollLayoutConstants.lightRowBackground;
    final darkPaint = Paint()
      ..color = PianoRollLayoutConstants.blackKeyRowBackground;
    final octaveDividerPaint = Paint()
      ..color = PianoRollLayoutConstants.octaveC4DividerColor
      ..strokeWidth = PianoRollLayoutConstants.beatLineStrokePx;

    for (
      var pitch = slice.visibleMinPitchMidi;
      pitch <= slice.visibleMaxPitchMidi;
      pitch++
    ) {
      final pitchClass = pitch % NotationViewConstants.semitonesPerOctave;
      final isBlack = PianoRollLayoutConstants.blackKeyPitchClasses.contains(
        pitchClass,
      );
      final rowTop =
          (PianoRollLayoutConstants.maxPitchMidi - pitch) * rowHeightPx -
          scrollYpx;
      canvas.drawRect(
        Rect.fromLTWH(0.0, rowTop, size.width, rowHeightPx),
        isBlack ? darkPaint : lightPaint,
      );
      if (pitchClass == 0) {
        final cBottom = rowTop + rowHeightPx;
        canvas.drawLine(
          Offset(0.0, cBottom),
          Offset(size.width, cBottom),
          octaveDividerPaint,
        );
      }
    }

    // 2. Paint culled vertical bar, beat, and subdivision grid lines.
    final barPaint = Paint()
      ..color = PianoRollLayoutConstants.barlineColor
      ..strokeWidth = PianoRollLayoutConstants.barlineStrokePx;
    final beatPaint = Paint()
      ..color = PianoRollLayoutConstants.beatLineColor
      ..strokeWidth = PianoRollLayoutConstants.beatLineStrokePx;
    final subPaint = Paint()
      ..color = PianoRollLayoutConstants.subdivisionLineColor
      ..strokeWidth = PianoRollLayoutConstants.subdivisionLineStrokePx;

    for (final line in slice.gridLines) {
      final x = line.tick.value * pixelsPerTick - scrollXpx;
      if (x < -PianoRollLayoutConstants.barlineStrokePx ||
          x > size.width + PianoRollLayoutConstants.barlineStrokePx) {
        continue;
      }
      final paint = line.isBarline
          ? barPaint
          : line.isBeatLine
          ? beatPaint
          : subPaint;
      canvas.drawLine(Offset(x, 0.0), Offset(x, size.height), paint);
    }

    // 3. Paint ONLY culled visible notes.
    final selectedStrokePaint = Paint()
      ..color = PianoRollLayoutConstants.noteSelectedStrokeColor
      ..style = PaintingStyle.stroke
      ..strokeWidth = PianoRollLayoutConstants.selectedNoteStrokeWidthPx;
    final radius = const Radius.circular(
      PianoRollLayoutConstants.noteBorderRadiusPx,
    );

    for (final note in slice.visibleNotes) {
      final start = playbackTimingMode == PlaybackTimingMode.raw
          ? note.rawStartTick.value
          : note.quantizedStartTick.value;
      final duration = playbackTimingMode == PlaybackTimingMode.raw
          ? note.rawDurationTicks
          : note.quantizedDurationTicks;
      final x = start * pixelsPerTick - scrollXpx;
      final width = math.max(
        PianoRollLayoutConstants.minNoteRectWidthPx,
        duration * pixelsPerTick,
      );
      final y =
          (PianoRollLayoutConstants.maxPitchMidi - note.pitchMidi) * rowHeightPx -
          scrollYpx;
      final rrect = RRect.fromRectAndRadius(
        Rect.fromLTWH(x, y, width, rowHeightPx),
        radius,
      );

      final opacity =
          PianoRollLayoutConstants.velocityMinOpacity +
          (note.velocity / MuseConstants.maxMidiVelocity) *
              PianoRollLayoutConstants.velocityOpacitySpan;
      final fillPaint = Paint()
        ..color = PianoRollLayoutConstants.noteFillColor.withValues(
          alpha: opacity.clamp(0.0, 1.0),
        );
      canvas.drawRRect(rrect, fillPaint);

      if (selectedNoteIds.contains(note.noteId)) {
        canvas.drawRRect(rrect, selectedStrokePaint);
      }
    }

    // 4. Ephemeral drag/resize/draw ghost outlines.
    if (dragPreviews.isNotEmpty) {
      final ghostFill = Paint()
        ..color = PianoRollLayoutConstants.ghostNoteColor.withValues(
          alpha: PianoRollLayoutConstants.ghostPreviewAlpha,
        );
      for (final preview in dragPreviews) {
        final x = preview.startTick.value * pixelsPerTick - scrollXpx;
        final width = math.max(
          PianoRollLayoutConstants.minNoteRectWidthPx,
          preview.durationTicks * pixelsPerTick,
        );
        final y =
            (PianoRollLayoutConstants.maxPitchMidi - preview.pitchMidi) *
                rowHeightPx -
            scrollYpx;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTWH(x, y, width, rowHeightPx),
            radius,
          ),
          ghostFill,
        );
      }
    }

    // 5. Marquee selection box.
    final marquee = marqueeRectViewportPx;
    if (marquee != null) {
      canvas.drawRect(
        marquee,
        Paint()
          ..color = PianoRollLayoutConstants.marqueeColor.withValues(
            alpha: PianoRollLayoutConstants.marqueeFillAlpha,
          ),
      );
      canvas.drawRect(
        marquee,
        Paint()
          ..color = PianoRollLayoutConstants.marqueeColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = PianoRollLayoutConstants.marqueeStrokeWidthPx,
      );
    }
  }

  @override
  bool shouldRepaint(covariant PianoRollGridPainter oldDelegate) =>
      oldDelegate.slice.workspaceRevision != slice.workspaceRevision ||
      oldDelegate.slice.partId != slice.partId ||
      oldDelegate.slice.visibleStartTick != slice.visibleStartTick ||
      oldDelegate.slice.visibleEndTick != slice.visibleEndTick ||
      oldDelegate.slice.visibleMinPitchMidi != slice.visibleMinPitchMidi ||
      oldDelegate.slice.visibleMaxPitchMidi != slice.visibleMaxPitchMidi ||
      oldDelegate.slice.effectiveSubdivisionTicks !=
          slice.effectiveSubdivisionTicks ||
      !listEquals(oldDelegate.slice.visibleNotes, slice.visibleNotes) ||
      !listEquals(oldDelegate.slice.gridLines, slice.gridLines) ||
      !setEquals(oldDelegate.selectedNoteIds, selectedNoteIds) ||
      !listEquals(oldDelegate.dragPreviews, dragPreviews) ||
      oldDelegate.pixelsPerTick != pixelsPerTick ||
      oldDelegate.rowHeightPx != rowHeightPx ||
      oldDelegate.scrollXpx != scrollXpx ||
      oldDelegate.scrollYpx != scrollYpx ||
      oldDelegate.playbackTimingMode != playbackTimingMode ||
      oldDelegate.marqueeRectViewportPx != marqueeRectViewportPx;
}

/// Paints the aligned audio take region computed over multi-tempo segments plus
/// live recording waveform feedback while recording is active on this part.
final class PianoRollTakeStripPainter extends CustomPainter {
  final PianoRollVisibleSlice slice;
  final double pixelsPerTick;
  final double scrollXpx;
  final bool isRecordingActivePart;
  final List<RecordingWaveformSample> liveWaveform;

  const PianoRollTakeStripPainter({
    required this.slice,
    required this.pixelsPerTick,
    required this.scrollXpx,
    required this.isRecordingActivePart,
    required this.liveWaveform,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = PianoRollLayoutConstants.takeStripBackgroundColor,
    );

    final startTick = slice.takeStartTick;
    final durationTicks = slice.takeDurationTicks;
    if (slice.activeTake != null && startTick != null && durationTicks != null) {
      final left = startTick.value * pixelsPerTick - scrollXpx;
      final width = math.max(
        PianoRollLayoutConstants.minNoteRectWidthPx,
        durationTicks.value * pixelsPerTick,
      );
      final takeRect = Rect.fromLTWH(left, 0.0, width, size.height);
      canvas.drawRect(
        takeRect,
        Paint()
          ..color = PianoRollLayoutConstants.takeStripFillColor.withValues(
            alpha: PianoRollLayoutConstants.takeStripFillAlpha,
          ),
      );
      canvas.drawRect(
        takeRect,
        Paint()
          ..color = PianoRollLayoutConstants.takeStripFillColor
          ..style = PaintingStyle.stroke
          ..strokeWidth = PianoRollLayoutConstants.takeStripBorderWidthPx,
      );
    }

    if (isRecordingActivePart && liveWaveform.isNotEmpty) {
      final baselineY =
          size.height * PianoRollLayoutConstants.takeStripBaselineFraction;
      final wavePaint = Paint()
        ..color = PianoRollLayoutConstants.playheadColor
        ..strokeWidth = PianoRollLayoutConstants.beatLineStrokePx;
      final stepPx = PianoRollLayoutConstants.velocityStemStrokePx;
      for (var i = 0; i < liveWaveform.length; i++) {
        final x = i * stepPx;
        if (x > size.width) break;
        final halfAmpPx =
            liveWaveform[i].inputPeak.clamp(
              TelemetryConstants.minLinearAmplitude,
              TelemetryConstants.maxLinearAmplitude,
            ) *
            baselineY;
        canvas.drawLine(
          Offset(x, baselineY - halfAmpPx),
          Offset(x, baselineY + halfAmpPx),
          wavePaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant PianoRollTakeStripPainter oldDelegate) =>
      oldDelegate.slice.activeTake?.takeId != slice.activeTake?.takeId ||
      oldDelegate.slice.takeStartTick != slice.takeStartTick ||
      oldDelegate.slice.takeDurationTicks != slice.takeDurationTicks ||
      oldDelegate.pixelsPerTick != pixelsPerTick ||
      oldDelegate.scrollXpx != scrollXpx ||
      oldDelegate.isRecordingActivePart != isRecordingActivePart ||
      oldDelegate.liveWaveform.length != liveWaveform.length;
}

/// `RepaintBoundary`-isolated O(1) painter for the 60 Hz playhead vertical cursor
/// and optional loop region bracket.
final class PianoRollPlayheadPainter extends CustomPainter {
  final ValueListenable<Tick> playheadTickListenable;
  final PianoRollViewportController viewportController;
  final TransportAndTelemetryController transportController;
  final VoidCallback? onPaintCallback;

  PianoRollPlayheadPainter({
    required this.playheadTickListenable,
    required this.viewportController,
    required this.transportController,
    this.onPaintCallback,
  }) : super(
         repaint: Listenable.merge([
           playheadTickListenable,
           viewportController,
           transportController,
         ]),
       );

  @override
  void paint(Canvas canvas, Size size) {
    onPaintCallback?.call();

    final pxPerTick = viewportController.pixelsPerTick;
    final scrollX = viewportController.scrollXpx;

    final loopRange = transportController.loopTickRange;
    if (transportController.isLoopEnabled && loopRange != null) {
      final loopLeft = loopRange.startTick.value * pxPerTick - scrollX;
      final loopRight = loopRange.endTick.value * pxPerTick - scrollX;
      if (loopRight >= 0.0 && loopLeft <= size.width) {
        final clampedLeft = math.max(0.0, loopLeft);
        final clampedRight = math.min(size.width, loopRight);
        canvas.drawRect(
          Rect.fromLTRB(clampedLeft, 0.0, clampedRight, size.height),
          Paint()
            ..color = PianoRollLayoutConstants.loopRegionBaseColor.withValues(
              alpha: PianoRollLayoutConstants.loopRegionFillAlpha,
            ),
        );
        canvas.drawRect(
          Rect.fromLTRB(
            clampedLeft,
            0.0,
            clampedRight,
            PianoRollLayoutConstants.loopBracketHeightPx,
          ),
          Paint()..color = PianoRollLayoutConstants.loopRegionBaseColor,
        );
      }
    }

    final playheadX = playheadTickListenable.value.value * pxPerTick - scrollX;
    if (playheadX >= -PianoRollLayoutConstants.playheadLineStrokePx &&
        playheadX <= size.width + PianoRollLayoutConstants.playheadLineStrokePx) {
      canvas.drawLine(
        Offset(playheadX, 0.0),
        Offset(playheadX, size.height),
        Paint()
          ..color = PianoRollLayoutConstants.playheadColor
          ..strokeWidth = PianoRollLayoutConstants.playheadLineStrokePx,
      );
    }
  }

  @override
  bool shouldRepaint(covariant PianoRollPlayheadPainter oldDelegate) =>
      oldDelegate.playheadTickListenable != playheadTickListenable ||
      oldDelegate.viewportController != viewportController ||
      oldDelegate.transportController != transportController;
}
