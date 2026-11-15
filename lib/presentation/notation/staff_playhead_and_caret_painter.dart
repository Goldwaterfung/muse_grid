/// RepaintBoundary-isolated playhead and engraving caret overlay for [StaffSystemView].
library;

import 'package:crisp_notation/crisp_notation.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/contracts/ids_and_units.dart';
import '../../domain/timeline/tempo_timeline_calculator.dart';
import '../theme/muse_presentation_constants.dart';
import 'staff_notation_view_controller.dart';

/// Lightweight `CustomPainter` driven by `playheadTick` + [StaffNotationViewController]
/// so 60 Hz playback never triggers `StaffSystemView` relayout or repaint.
final class StaffPlayheadAndCaretPainter extends CustomPainter {
  final ValueListenable<Tick> playheadTickListenable;
  final StaffNotationViewController staffController;
  final ITempoTimelineCalculator? Function() calculatorProvider;
  final VoidCallback? onPaintCallback;

  StaffPlayheadAndCaretPainter({
    required this.playheadTickListenable,
    required this.staffController,
    required this.calculatorProvider,
    this.onPaintCallback,
  }) : super(repaint: Listenable.merge([playheadTickListenable, staffController]));

  @override
  void paint(Canvas canvas, Size size) {
    onPaintCallback?.call();

    final layout = staffController.cachedLayout;
    final calculator = calculatorProvider();
    if (layout == null || calculator == null || layout.staves.isEmpty) {
      return;
    }

    final staffSpace =
        NotationViewConstants.baseStaffSpacePx * staffController.zoomScale;
    final focusedStaffIdx =
        staffController.layoutStaffIndexForFocusedStaff(layout) ?? 0;

    final caretX = _tickToPixelX(
      tick: staffController.cursorTick,
      layout: layout,
      staffIndex: focusedStaffIdx,
      staffSpace: staffSpace,
      calculator: calculator,
    );
    if (caretX != null) {
      final staffTopPx =
          (layout.staffTop(focusedStaffIdx) - layout.top) * staffSpace;
      final staffBottomPx =
          staffTopPx +
          NotationViewConstants.standardStaffHeightSpaces * staffSpace;
      final caretPaint = Paint()
        ..color = NotationViewConstants.caretColor
        ..strokeWidth = NotationViewConstants.caretLineStrokePx;
      canvas.drawLine(
        Offset(caretX, staffTopPx),
        Offset(caretX, staffBottomPx),
        caretPaint,
      );
    }

    final playheadX = _tickToPixelX(
      tick: playheadTickListenable.value,
      layout: layout,
      staffIndex: 0,
      staffSpace: staffSpace,
      calculator: calculator,
    );
    if (playheadX != null) {
      final playheadPaint = Paint()
        ..color = NotationViewConstants.playheadColor
        ..strokeWidth = NotationViewConstants.playheadLineStrokePx;
      canvas.drawLine(
        Offset(playheadX, 0.0),
        Offset(playheadX, layout.height * staffSpace),
        playheadPaint,
      );
    }
  }

  static double? _tickToPixelX({
    required Tick tick,
    required StaffSystemLayout layout,
    required int staffIndex,
    required double staffSpace,
    required ITempoTimelineCalculator calculator,
  }) {
    final regions = layout.staves[staffIndex].measureRegions;
    if (regions.isEmpty) {
      return null;
    }

    final pickupOffset =
        calculator is TempoTimelineCalculator && calculator.pickupTicks > 0
        ? 0
        : -1;
    final pos = calculator.tickToBarBeatTick(tick);
    final measureIdx = (pos.measureNumber + pickupOffset).clamp(
      0,
      regions.length - 1,
    );
    final region = regions[measureIdx];
    final fraction = pos.measureDurationTicks > 0
        ? (pos.tickInMeasure / pos.measureDurationTicks).clamp(0.0, 1.0)
        : 0.0;
    final xSpaces =
        RenderStaffSystemView.leftInset +
        region.startX +
        (region.endX - region.startX) * fraction;
    return xSpaces * staffSpace;
  }

  @override
  bool shouldRepaint(covariant StaffPlayheadAndCaretPainter oldDelegate) =>
      oldDelegate.playheadTickListenable != playheadTickListenable ||
      oldDelegate.staffController != staffController ||
      oldDelegate.calculatorProvider != calculatorProvider;
}
