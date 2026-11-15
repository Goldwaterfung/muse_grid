/// Composite Layer 5 Piano Roll workspace panel with synchronized ruler,
/// audio take strip, 128-key gutter, viewport-culled note grid, velocity lane,
/// and RepaintBoundary-isolated playhead overlay.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../domain/models/score_models.dart';
import '../controllers/transport_and_telemetry_controller.dart';
import '../controllers/workspace_shell_controller.dart';
import '../theme/muse_presentation_constants.dart';
import 'piano_roll_grid_painter.dart';
import 'piano_roll_viewport_controller.dart';

/// Synchronized viewport-culled Piano Roll editor bound to [PianoRollViewportController].
final class PianoRollPanel extends StatefulWidget {
  final PianoRollViewportController controller;
  final WorkspaceShellController workspaceController;
  final TransportAndTelemetryController transportController;
  final VoidCallback? onGridPaintForTest;
  final VoidCallback? onPlayheadPaintForTest;

  const PianoRollPanel({
    super.key,
    required this.controller,
    required this.workspaceController,
    required this.transportController,
    this.onGridPaintForTest,
    this.onPlayheadPaintForTest,
  });

  @override
  State<PianoRollPanel> createState() => _PianoRollPanelState();
}

final class _PianoRollPanelState extends State<PianoRollPanel> {
  bool _isLoopEditMode = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([
        widget.controller,
        widget.workspaceController,
        widget.transportController,
      ]),
      builder: (context, _) {
        final ws = widget.controller.activeWorkspace;
        if (ws == null) {
          return const Center(child: Text('No project workspace is open.'));
        }

        final activePartId = widget.controller.activePartId;
        final activePart = activePartId == null
            ? null
            : ws.aggregate.parts
                  .where((p) => p.partId == activePartId)
                  .firstOrNull;
        final slice = widget.controller.computeVisibleSlice();
        final canvasWidth = widget.controller.totalCanvasWidthPx;
        final canvasHeight = widget.controller.totalCanvasHeightPx;
        final isRecordingActivePart =
            widget.transportController.isRecording &&
            widget.transportController.armedPartId == activePartId;

        return CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.delete): () =>
                unawaited(widget.controller.deleteSelectedNotes()),
            const SingleActivator(LogicalKeyboardKey.backspace): () =>
                unawaited(widget.controller.deleteSelectedNotes()),
          },
          child: Focus(
            autofocus: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _PianoRollTopBar(
                  controller: widget.controller,
                  activePartName: activePart?.name ?? 'No Part',
                  isLoopEditMode: _isLoopEditMode,
                  onToggleLoopEditMode: (val) =>
                      setState(() => _isLoopEditMode = val),
                ),
                if (widget.controller.lastError != null)
                  _PianoRollErrorBanner(
                    error: widget.controller.lastError!,
                    onDismiss: widget.controller.dismissError,
                  ),
                Expanded(
                  child: LayoutBuilder(
                    builder: (context, constraints) {
                      final scrollbarSize =
                          PianoRollLayoutConstants.scrollbarThicknessPx;
                      final gridViewportWidth = math.max(
                        PianoRollLayoutConstants.minViewportExtentPx,
                        constraints.maxWidth -
                            PianoRollLayoutConstants.keyGutterWidthPx -
                            scrollbarSize,
                      );
                      final gridViewportHeight = math.max(
                        PianoRollLayoutConstants.minViewportExtentPx,
                        constraints.maxHeight -
                            PianoRollLayoutConstants.rulerHeightPx -
                            PianoRollLayoutConstants.takeStripHeightPx -
                            PianoRollLayoutConstants.velocityLaneHeightPx -
                            scrollbarSize,
                      );
                      if (gridViewportWidth !=
                              widget.controller.viewportWidthPx ||
                          gridViewportHeight !=
                              widget.controller.viewportHeightPx ||
                          !widget.controller.hasInitializedScrollY) {
                        WidgetsBinding.instance.addPostFrameCallback((_) {
                          if (mounted) {
                            widget.controller.updateViewportGeometry(
                              viewportWidthPx: gridViewportWidth,
                              viewportHeightPx: gridViewportHeight,
                              centerInitialPitchIfUnset: true,
                            );
                          }
                        });
                      }

                      final gridCursor = widget.controller.isPanning
                          ? SystemMouseCursors.grabbing
                          : widget.controller.activeTool ==
                                PianoRollToolMode.pan
                          ? SystemMouseCursors.grab
                          : MouseCursor.defer;

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          // Row 1: Corner + Ruler Header + Scrollbar Corner
                          SizedBox(
                            height: PianoRollLayoutConstants.rulerHeightPx,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Container(
                                  width:
                                      PianoRollLayoutConstants.keyGutterWidthPx,
                                  color: PianoRollLayoutConstants
                                      .rulerBackgroundColor,
                                  alignment: Alignment.center,
                                  child: const Text(
                                    'Bar',
                                    style: TextStyle(
                                      color:
                                          PianoRollLayoutConstants.rulerTextColor,
                                      fontSize: PianoRollLayoutConstants
                                          .rulerLabelFontSizePx,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: PianoRollRulerHeader(
                                    slice: slice,
                                    controller: widget.controller,
                                    workspaceController:
                                        widget.workspaceController,
                                    transportController:
                                        widget.transportController,
                                    isLoopDragMode: _isLoopEditMode,
                                  ),
                                ),
                                Container(
                                  width: scrollbarSize,
                                  color: PianoRollLayoutConstants
                                      .rulerBackgroundColor,
                                ),
                              ],
                            ),
                          ),
                          // Row 2: Take Corner + Take Strip + Scrollbar Corner
                          SizedBox(
                            height: PianoRollLayoutConstants.takeStripHeightPx,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Container(
                                  width:
                                      PianoRollLayoutConstants.keyGutterWidthPx,
                                  color: PianoRollLayoutConstants
                                      .takeStripBackgroundColor,
                                  alignment: Alignment.center,
                                  child: const Text(
                                    'Audio',
                                    style: TextStyle(
                                      color:
                                          PianoRollLayoutConstants.rulerTextColor,
                                      fontSize: PianoRollLayoutConstants
                                          .rulerLabelFontSizePx,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: _PianoRollScrollInputRegion(
                                    controller: widget.controller,
                                    allowVertical: false,
                                    behavior: HitTestBehavior.opaque,
                                    child: IgnorePointer(
                                      child: ClipRect(
                                        child: SizedBox.expand(
                                          child: CustomPaint(
                                            key: const Key(
                                              'piano_roll_take_strip',
                                            ),
                                          painter: PianoRollTakeStripPainter(
                                            slice: slice,
                                            pixelsPerTick:
                                                widget.controller.pixelsPerTick,
                                            scrollXpx:
                                                widget.controller.scrollXpx,
                                            isRecordingActivePart:
                                                isRecordingActivePart,
                                            liveWaveform: widget
                                                .transportController
                                                .liveRecordingWaveform
                                                .value,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                                ),
                                Container(
                                  width: scrollbarSize,
                                  color: PianoRollLayoutConstants
                                      .takeStripBackgroundColor,
                                ),
                              ],
                            ),
                          ),
                          // Row 3: Piano Key Gutter + Culled Grid + Playhead Overlay + Vertical Scrollbar
                          Expanded(
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                SizedBox(
                                  width:
                                      PianoRollLayoutConstants.keyGutterWidthPx,
                                  child: PianoKeyGutter(
                                    controller: widget.controller,
                                  ),
                                ),
                                Expanded(
                                  child: Stack(
                                    children: <Widget>[
                                      Positioned.fill(
                                        child: RepaintBoundary(
                                          child: _PianoRollScrollInputRegion(
                                            controller: widget.controller,
                                            child: MouseRegion(
                                              cursor: gridCursor,
                                              child: Listener(
                                                key: const Key(
                                                  'piano_roll_grid_canvas',
                                                ),
                                                behavior:
                                                    HitTestBehavior.opaque,
                                                onPointerDown: (event) {
                                                  final spaceHeld =
                                                      HardwareKeyboard
                                                          .instance
                                                          .logicalKeysPressed
                                                          .contains(
                                                            LogicalKeyboardKey
                                                                .space,
                                                          );
                                                  widget.controller
                                                      .onCanvasPointerDown(
                                                        event.localPosition,
                                                        buttons: event.buttons,
                                                        isPanModifierPressed:
                                                            spaceHeld,
                                                      );
                                                },
                                                onPointerMove: (event) => widget
                                                    .controller
                                                    .onCanvasPointerMove(
                                                      event.localPosition,
                                                    ),
                                                onPointerUp: (_) => unawaited(
                                                  widget.controller
                                                      .onCanvasPointerUp(),
                                                ),
                                                onPointerCancel: (_) => widget
                                                    .controller
                                                    .onCanvasPointerCancel(),
                                                child: ClipRect(
                                                  child: CustomPaint(
                                                    painter: PianoRollGridPainter(
                                                      slice: slice,
                                                      selectedNoteIds: widget
                                                          .controller
                                                          .selectedNoteIds,
                                                      dragPreviews: widget
                                                          .controller
                                                          .dragPreviews,
                                                      pixelsPerTick: widget
                                                          .controller
                                                          .pixelsPerTick,
                                                      rowHeightPx: widget
                                                          .controller
                                                          .rowHeightPx,
                                                      scrollXpx: widget
                                                          .controller
                                                          .scrollXpx,
                                                      scrollYpx: widget
                                                          .controller
                                                          .scrollYpx,
                                                      playbackTimingMode: ws
                                                          .aggregate
                                                          .project
                                                          .playbackTimingMode,
                                                      marqueeRectViewportPx:
                                                          widget
                                                              .controller
                                                              .marqueeRectViewportPx,
                                                      onPaintCallback: widget
                                                          .onGridPaintForTest,
                                                    ),
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                      Positioned.fill(
                                        child: RepaintBoundary(
                                          child: IgnorePointer(
                                            child: ClipRect(
                                              child: CustomPaint(
                                                key: const Key(
                                                  'piano_roll_playhead_overlay',
                                                ),
                                                painter: PianoRollPlayheadPainter(
                                                  playheadTickListenable: widget
                                                      .transportController
                                                      .playheadTick,
                                                  viewportController:
                                                      widget.controller,
                                                  transportController:
                                                      widget.transportController,
                                                  onPaintCallback: widget
                                                      .onPlayheadPaintForTest,
                                                ),
                                              ),
                                            ),
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                SizedBox(
                                  width: scrollbarSize,
                                  child: _PianoRollAxisScrollbar(
                                    key: const Key(
                                      'piano_roll_vertical_scrollbar',
                                    ),
                                    axis: Axis.vertical,
                                    offsetPx: widget.controller.scrollYpx,
                                    viewportExtentPx: gridViewportHeight,
                                    contentExtentPx: canvasHeight,
                                    onScrollToPx: (y) => widget.controller
                                        .scrollTo(scrollYpx: y),
                                  ),
                                ),
                              ],
                            ),
                          ),
                          // Row 4: Velocity Corner + Velocity Lane + Scrollbar Corner
                          SizedBox(
                            height:
                                PianoRollLayoutConstants.velocityLaneHeightPx,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Container(
                                  width:
                                      PianoRollLayoutConstants.keyGutterWidthPx,
                                  color: PianoRollLayoutConstants
                                      .velocityLaneBackgroundColor,
                                  alignment: Alignment.center,
                                  child: const Text(
                                    'Vel',
                                    style: TextStyle(
                                      color:
                                          PianoRollLayoutConstants.rulerTextColor,
                                      fontSize: PianoRollLayoutConstants
                                          .rulerLabelFontSizePx,
                                    ),
                                  ),
                                ),
                                Expanded(
                                  child: PianoRollVelocityLane(
                                    slice: slice,
                                    controller: widget.controller,
                                    playbackTimingMode:
                                        ws.aggregate.project.playbackTimingMode,
                                  ),
                                ),
                                Container(
                                  width: scrollbarSize,
                                  color: PianoRollLayoutConstants
                                      .velocityLaneBackgroundColor,
                                ),
                              ],
                            ),
                          ),
                          // Row 5: Bottom Corner + Horizontal Scrollbar + Bottom-Right Corner
                          SizedBox(
                            height: scrollbarSize,
                            child: Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: <Widget>[
                                Container(
                                  width:
                                      PianoRollLayoutConstants.keyGutterWidthPx,
                                  color: PianoRollLayoutConstants
                                      .scrollbarTrackColor,
                                ),
                                Expanded(
                                  child: _PianoRollAxisScrollbar(
                                    key: const Key(
                                      'piano_roll_horizontal_scrollbar',
                                    ),
                                    axis: Axis.horizontal,
                                    offsetPx: widget.controller.scrollXpx,
                                    viewportExtentPx: gridViewportWidth,
                                    contentExtentPx: canvasWidth,
                                    onScrollToPx: (x) => widget.controller
                                        .scrollTo(scrollXpx: x),
                                  ),
                                ),
                                Container(
                                  width: scrollbarSize,
                                  color: PianoRollLayoutConstants
                                      .scrollbarTrackColor,
                                ),
                              ],
                            ),
                          ),
                        ],
                      );
                    },
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

/// Translates mouse-wheel (`PointerScrollEvent`) and trackpad two-finger
/// (`PointerPanZoomUpdateEvent`) gestures into [PianoRollViewportController.panBy].
final class _PianoRollScrollInputRegion extends StatelessWidget {
  final PianoRollViewportController controller;
  final bool allowHorizontal;
  final bool allowVertical;
  final HitTestBehavior behavior;
  final Widget child;

  const _PianoRollScrollInputRegion({
    required this.controller,
    this.allowHorizontal = true,
    this.allowVertical = true,
    this.behavior = HitTestBehavior.translucent,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: behavior,
      onPointerSignal: (event) {
        if (event is! PointerScrollEvent) {
          return;
        }
        GestureBinding.instance.pointerSignalResolver.register(event, (
          PointerSignalEvent resolved,
        ) {
          final scroll = resolved as PointerScrollEvent;
          final shiftHeld = HardwareKeyboard.instance.isShiftPressed;
          final rawDx = scroll.scrollDelta.dx;
          final rawDy = scroll.scrollDelta.dy;
          final double dx;
          final double dy;
          if ((shiftHeld || !allowVertical) && rawDx == 0.0 && allowHorizontal) {
            dx = rawDy;
            dy = 0.0;
          } else {
            dx = allowHorizontal ? rawDx : 0.0;
            dy = allowVertical ? rawDy : 0.0;
          }
          controller.panBy(dxPx: dx, dyPx: dy);
        });
      },
      onPointerPanZoomUpdate: (event) {
        final dx = allowHorizontal ? -event.localPanDelta.dx : 0.0;
        final dy = allowVertical ? -event.localPanDelta.dy : 0.0;
        if (dx != 0.0 || dy != 0.0) {
          controller.panBy(dxPx: dx, dyPx: dy);
        }
      },
      child: child,
    );
  }
}

/// Interactive single-axis scrollbar bound directly to [PianoRollViewportController]
/// scroll coordinates without maintaining an auxiliary `ScrollController`.
final class _PianoRollAxisScrollbar extends StatefulWidget {
  final Axis axis;
  final double offsetPx;
  final double viewportExtentPx;
  final double contentExtentPx;
  final ValueChanged<double> onScrollToPx;

  const _PianoRollAxisScrollbar({
    super.key,
    required this.axis,
    required this.offsetPx,
    required this.viewportExtentPx,
    required this.contentExtentPx,
    required this.onScrollToPx,
  });

  @override
  State<_PianoRollAxisScrollbar> createState() =>
      _PianoRollAxisScrollbarState();
}

final class _PianoRollAxisScrollbarState extends State<_PianoRollAxisScrollbar> {
  bool _isDragging = false;
  double? _dragLastAxisCoord;
  double _dragPendingOffsetPx = PianoRollLayoutConstants.minScrollPx;

  double _axisCoord(Offset position) =>
      widget.axis == Axis.horizontal ? position.dx : position.dy;

  @override
  Widget build(BuildContext context) {
    final isHorizontal = widget.axis == Axis.horizontal;
    final padding = PianoRollLayoutConstants.scrollbarTrackPaddingPx;

    return LayoutBuilder(
      builder: (context, constraints) {
        final trackExtentPx = math.max(
          PianoRollLayoutConstants.minViewportExtentPx,
          isHorizontal ? constraints.maxWidth : constraints.maxHeight,
        );
        final maxScroll = math.max(
          PianoRollLayoutConstants.minScrollPx,
          widget.contentExtentPx - widget.viewportExtentPx,
        );
        final hasScrollableSpan = maxScroll > PianoRollLayoutConstants.minScrollPx;

        final double thumbExtent;
        final double maxThumbTravel;
        final double thumbOffset;
        if (!hasScrollableSpan) {
          thumbExtent = trackExtentPx;
          maxThumbTravel = PianoRollLayoutConstants.minScrollPx;
          thumbOffset = PianoRollLayoutConstants.minScrollPx;
        } else {
          final proportionalThumb =
              (widget.viewportExtentPx /
                  math.max(
                    PianoRollLayoutConstants.minViewportExtentPx,
                    widget.contentExtentPx,
                  )) *
              trackExtentPx;
          thumbExtent = proportionalThumb
              .clamp(
                math.min(
                  PianoRollLayoutConstants.scrollbarMinThumbExtentPx,
                  trackExtentPx,
                ),
                trackExtentPx,
              )
              .toDouble();
          maxThumbTravel = math.max(
            PianoRollLayoutConstants.minScrollPx,
            trackExtentPx - thumbExtent,
          );
          final normalizedOffset = (widget.offsetPx / maxScroll)
              .clamp(0.0, 1.0)
              .toDouble();
          thumbOffset = normalizedOffset * maxThumbTravel;
        }

        final thumbRect = isHorizontal
            ? Positioned(
                left: thumbOffset,
                top: padding,
                bottom: padding,
                width: thumbExtent,
                child: _buildThumb(),
              )
            : Positioned(
                top: thumbOffset,
                left: padding,
                right: padding,
                height: thumbExtent,
                child: _buildThumb(),
              );

        return Listener(
          behavior: HitTestBehavior.opaque,
          onPointerDown: (event) {
            if (!hasScrollableSpan ||
                maxThumbTravel <= PianoRollLayoutConstants.minScrollPx) {
              return;
            }
            final coord = _axisCoord(event.localPosition);
            final insideThumb =
                coord >= thumbOffset && coord <= thumbOffset + thumbExtent;
            double startingOffset = widget.offsetPx.clamp(
              PianoRollLayoutConstants.minScrollPx,
              maxScroll,
            );
            if (!insideThumb) {
              final targetThumbOffset =
                  (coord -
                          thumbExtent *
                              PianoRollLayoutConstants.viewportCenterFraction)
                      .clamp(
                        PianoRollLayoutConstants.minScrollPx,
                        maxThumbTravel,
                      )
                      .toDouble();
              startingOffset = (targetThumbOffset / maxThumbTravel) * maxScroll;
              widget.onScrollToPx(startingOffset);
            }
            setState(() {
              _isDragging = true;
              _dragLastAxisCoord = coord;
              _dragPendingOffsetPx = startingOffset;
            });
          },
          onPointerMove: (event) {
            if (!_isDragging ||
                _dragLastAxisCoord == null ||
                !hasScrollableSpan ||
                maxThumbTravel <= PianoRollLayoutConstants.minScrollPx) {
              return;
            }
            final coord = _axisCoord(event.localPosition);
            final deltaPx = coord - _dragLastAxisCoord!;
            _dragLastAxisCoord = coord;
            final deltaScroll = deltaPx * (maxScroll / maxThumbTravel);
            final nextOffset = (_dragPendingOffsetPx + deltaScroll)
                .clamp(PianoRollLayoutConstants.minScrollPx, maxScroll)
                .toDouble();
            _dragPendingOffsetPx = nextOffset;
            widget.onScrollToPx(nextOffset);
          },
          onPointerUp: (_) {
            if (_isDragging) {
              setState(() {
                _isDragging = false;
                _dragLastAxisCoord = null;
              });
            }
          },
          onPointerCancel: (_) {
            if (_isDragging) {
              setState(() {
                _isDragging = false;
                _dragLastAxisCoord = null;
              });
            }
          },
          child: ColoredBox(
            color: PianoRollLayoutConstants.scrollbarTrackColor,
            child: Stack(children: <Widget>[thumbRect]),
          ),
        );
      },
    );
  }

  Widget _buildThumb() {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: _isDragging
            ? PianoRollLayoutConstants.scrollbarThumbActiveColor
            : PianoRollLayoutConstants.scrollbarThumbColor,
        borderRadius: BorderRadius.circular(
          PianoRollLayoutConstants.scrollbarThumbRadiusPx,
        ),
      ),
    );
  }
}

/// Interactive horizontal timeline ruler supporting bar numbers, quantized seek,
/// and normalized loop-range drags (`endTick > startTick`).
final class PianoRollRulerHeader extends StatefulWidget {
  final PianoRollVisibleSlice slice;
  final PianoRollViewportController controller;
  final WorkspaceShellController workspaceController;
  final TransportAndTelemetryController transportController;
  final bool isLoopDragMode;

  const PianoRollRulerHeader({
    super.key,
    required this.slice,
    required this.controller,
    required this.workspaceController,
    required this.transportController,
    required this.isLoopDragMode,
  });

  @override
  State<PianoRollRulerHeader> createState() => _PianoRollRulerHeaderState();
}

final class _PianoRollRulerHeaderState extends State<PianoRollRulerHeader> {
  Tick? _loopAnchorTick;

  Tick _quantizeAtLocalX(double localX) {
    final raw = widget.controller.screenXToTick(localX);
    final calc = widget.workspaceController
        .buildTimelineCalculatorForActiveWorkspace();
    if (calc == null) {
      return raw;
    }
    return calc.quantizeTick(
      raw,
      snapSubdivisionTicks: Tick(widget.controller.selectedSnapTicks),
    );
  }

  void _applyLoopRangeToLocalX(double localX) {
    final anchor = _loopAnchorTick;
    if (anchor == null) return;
    final current = _quantizeAtLocalX(localX);
    final start = math.min(anchor.value, current.value);
    final end = math.max(
      math.max(anchor.value, current.value),
      start + widget.controller.selectedSnapTicks,
    );
    widget.transportController.setLoopTickRange(
      enabled: true,
      startTick: Tick(start),
      endTick: Tick(end),
    );
  }

  @override
  Widget build(BuildContext context) {
    return _PianoRollScrollInputRegion(
      controller: widget.controller,
      allowVertical: false,
      child: Listener(
        key: const Key('piano_roll_ruler_header'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          final tick = _quantizeAtLocalX(event.localPosition.dx);
          if (widget.isLoopDragMode) {
            _loopAnchorTick = tick;
            _applyLoopRangeToLocalX(event.localPosition.dx);
          } else {
            widget.transportController.seekToTick(tick);
          }
        },
        onPointerMove: (event) {
          if (widget.isLoopDragMode && _loopAnchorTick != null) {
            _applyLoopRangeToLocalX(event.localPosition.dx);
          } else {
            final tick = _quantizeAtLocalX(event.localPosition.dx);
            widget.transportController.seekToTick(tick);
          }
        },
        onPointerUp: (_) => _loopAnchorTick = null,
        onPointerCancel: (_) => _loopAnchorTick = null,
        child: ClipRect(
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _RulerPainter(
                slice: widget.slice,
                pixelsPerTick: widget.controller.pixelsPerTick,
                scrollXpx: widget.controller.scrollXpx,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _RulerPainter extends CustomPainter {
  final PianoRollVisibleSlice slice;
  final double pixelsPerTick;
  final double scrollXpx;

  const _RulerPainter({
    required this.slice,
    required this.pixelsPerTick,
    required this.scrollXpx,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = PianoRollLayoutConstants.rulerBackgroundColor,
    );
    final barPaint = Paint()
      ..color = PianoRollLayoutConstants.barlineColor
      ..strokeWidth = PianoRollLayoutConstants.barlineStrokePx;

    for (final line in slice.gridLines) {
      if (!line.isBarline) continue;
      final x = line.tick.value * pixelsPerTick - scrollXpx;
      if (x < 0.0 || x > size.width) continue;
      canvas.drawLine(Offset(x, 0.0), Offset(x, size.height), barPaint);
      final tp = TextPainter(
        text: TextSpan(
          text: '${line.measureNumber}',
          style: const TextStyle(
            color: PianoRollLayoutConstants.rulerTextColor,
            fontSize: PianoRollLayoutConstants.rulerLabelFontSizePx,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          x + PianoRollLayoutConstants.keyLabelPaddingPx,
          PianoRollLayoutConstants.keyLabelPaddingPx,
        ),
      );
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _RulerPainter oldDelegate) =>
      oldDelegate.pixelsPerTick != pixelsPerTick ||
      oldDelegate.scrollXpx != scrollXpx ||
      oldDelegate.slice.visibleStartTick != slice.visibleStartTick ||
      oldDelegate.slice.visibleEndTick != slice.visibleEndTick ||
      oldDelegate.slice.gridLines.length != slice.gridLines.length;
}

/// Vertically synchronized 128-key piano keyboard gutter auditing pitch changes.
final class PianoKeyGutter extends StatelessWidget {
  final PianoRollViewportController controller;

  const PianoKeyGutter({super.key, required this.controller});

  @override
  Widget build(BuildContext context) {
    return _PianoRollScrollInputRegion(
      controller: controller,
      allowHorizontal: false,
      child: Listener(
        key: const Key('piano_key_gutter'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) => controller.auditionKeyGutterPitchDown(
          controller.screenYToPitchMidi(event.localPosition.dy),
        ),
        onPointerMove: (event) => controller.auditionKeyGutterPitchMove(
          controller.screenYToPitchMidi(event.localPosition.dy),
        ),
        onPointerUp: (_) => controller.auditionKeyGutterPitchUp(),
        onPointerCancel: (_) => controller.auditionKeyGutterPitchUp(),
        child: ClipRect(
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _PianoKeyGutterPainter(
                minPitchMidi: controller.visibleMinPitchMidi,
                maxPitchMidi: controller.visibleMaxPitchMidi,
                rowHeightPx: controller.rowHeightPx,
                scrollYpx: controller.scrollYpx,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _PianoKeyGutterPainter extends CustomPainter {
  final int minPitchMidi;
  final int maxPitchMidi;
  final double rowHeightPx;
  final double scrollYpx;

  const _PianoKeyGutterPainter({
    required this.minPitchMidi,
    required this.maxPitchMidi,
    required this.rowHeightPx,
    required this.scrollYpx,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final whitePaint = Paint()
      ..color = PianoRollLayoutConstants.whiteKeyBackgroundColor;
    final blackPaint = Paint()
      ..color = PianoRollLayoutConstants.blackKeyBackgroundColor;
    final dividerPaint = Paint()
      ..color = PianoRollLayoutConstants.keyDividerColor
      ..strokeWidth = PianoRollLayoutConstants.subdivisionLineStrokePx;

    for (var pitch = minPitchMidi; pitch <= maxPitchMidi; pitch++) {
      final pc = pitch % NotationViewConstants.semitonesPerOctave;
      final isBlack = PianoRollLayoutConstants.blackKeyPitchClasses.contains(pc);
      final top =
          (PianoRollLayoutConstants.maxPitchMidi - pitch) * rowHeightPx -
          scrollYpx;
      canvas.drawRect(
        Rect.fromLTWH(0.0, top, size.width, rowHeightPx),
        isBlack ? blackPaint : whitePaint,
      );
      canvas.drawLine(
        Offset(0.0, top + rowHeightPx),
        Offset(size.width, top + rowHeightPx),
        dividerPaint,
      );

      final octave =
          (pitch ~/ NotationViewConstants.semitonesPerOctave) -
          PianoRollLayoutConstants.midiOctaveDisplayOffset;
      final name = '${PianoRollLayoutConstants.pitchClassNames[pc]}$octave';
      final tp = TextPainter(
        text: TextSpan(
          text: name,
          style: TextStyle(
            color: isBlack
                ? PianoRollLayoutConstants.blackKeyLabelColor
                : PianoRollLayoutConstants.whiteKeyLabelColor,
            fontSize: PianoRollLayoutConstants.keyLabelFontSizePx,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(
        canvas,
        Offset(
          PianoRollLayoutConstants.keyLabelPaddingPx,
          top +
              math.max(
                0.0,
                (rowHeightPx - tp.height) *
                    PianoRollLayoutConstants.takeStripBaselineFraction,
              ),
        ),
      );
      tp.dispose();
    }
  }

  @override
  bool shouldRepaint(covariant _PianoKeyGutterPainter oldDelegate) =>
      oldDelegate.minPitchMidi != minPitchMidi ||
      oldDelegate.maxPitchMidi != maxPitchMidi ||
      oldDelegate.rowHeightPx != rowHeightPx ||
      oldDelegate.scrollYpx != scrollYpx;
}

/// Horizontally synchronized velocity stem editor bound to `UpdateNotesCommand`.
final class PianoRollVelocityLane extends StatefulWidget {
  final PianoRollVisibleSlice slice;
  final PianoRollViewportController controller;
  final PlaybackTimingMode playbackTimingMode;

  const PianoRollVelocityLane({
    super.key,
    required this.slice,
    required this.controller,
    required this.playbackTimingMode,
  });

  @override
  State<PianoRollVelocityLane> createState() => _PianoRollVelocityLaneState();
}

final class _PianoRollVelocityLaneState extends State<PianoRollVelocityLane> {
  NoteId? _activeVelocityNoteId;
  int? _previewVelocity;

  NoteId? _hitTestStemNoteId(double localX) {
    NoteId? closest;
    var bestDist = double.infinity;
    final pxPerTick = widget.controller.pixelsPerTick;
    final scrollX = widget.controller.scrollXpx;
    for (final note in widget.slice.visibleNotes) {
      final start = widget.playbackTimingMode == PlaybackTimingMode.raw
          ? note.rawStartTick.value
          : note.quantizedStartTick.value;
      final stemX = start * pxPerTick - scrollX;
      final dist = (localX - stemX).abs();
      if (dist <= PianoRollLayoutConstants.noteResizeHandleWidthPx &&
          dist < bestDist) {
        bestDist = dist;
        closest = note.noteId;
      }
    }
    return closest;
  }

  int _velocityForLocalY(double localY, double laneHeight) {
    final normalized = 1.0 - (localY / math.max(1.0, laneHeight)).clamp(0.0, 1.0);
    return (normalized * MuseConstants.maxMidiVelocity)
        .round()
        .clamp(MuseConstants.minMidiVelocity, MuseConstants.maxMidiVelocity);
  }

  @override
  Widget build(BuildContext context) {
    return _PianoRollScrollInputRegion(
      controller: widget.controller,
      allowVertical: false,
      child: Listener(
        key: const Key('piano_roll_velocity_lane'),
        behavior: HitTestBehavior.opaque,
        onPointerDown: (event) {
          final hitId = _hitTestStemNoteId(event.localPosition.dx);
          if (hitId == null) return;
          setState(() {
            _activeVelocityNoteId = hitId;
            _previewVelocity = _velocityForLocalY(
              event.localPosition.dy,
              PianoRollLayoutConstants.velocityLaneHeightPx,
            );
          });
        },
        onPointerMove: (event) {
          if (_activeVelocityNoteId == null) return;
          setState(() {
            _previewVelocity = _velocityForLocalY(
              event.localPosition.dy,
              PianoRollLayoutConstants.velocityLaneHeightPx,
            );
          });
        },
        onPointerUp: (_) {
          final noteId = _activeVelocityNoteId;
          final vel = _previewVelocity;
          setState(() {
            _activeVelocityNoteId = null;
            _previewVelocity = null;
          });
          if (noteId != null && vel != null) {
            unawaited(
              widget.controller.updateNotesVelocity(
                noteId: noteId,
                velocity: vel,
              ),
            );
          }
        },
        onPointerCancel: (_) => setState(() {
          _activeVelocityNoteId = null;
          _previewVelocity = null;
        }),
        child: ClipRect(
          child: SizedBox.expand(
            child: CustomPaint(
              painter: _VelocityLanePainter(
                slice: widget.slice,
                selectedNoteIds: widget.controller.selectedNoteIds,
                pixelsPerTick: widget.controller.pixelsPerTick,
                scrollXpx: widget.controller.scrollXpx,
                playbackTimingMode: widget.playbackTimingMode,
                previewNoteId: _activeVelocityNoteId,
                previewVelocity: _previewVelocity,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

final class _VelocityLanePainter extends CustomPainter {
  final PianoRollVisibleSlice slice;
  final Set<NoteId> selectedNoteIds;
  final double pixelsPerTick;
  final double scrollXpx;
  final PlaybackTimingMode playbackTimingMode;
  final NoteId? previewNoteId;
  final int? previewVelocity;

  const _VelocityLanePainter({
    required this.slice,
    required this.selectedNoteIds,
    required this.pixelsPerTick,
    required this.scrollXpx,
    required this.playbackTimingMode,
    required this.previewNoteId,
    required this.previewVelocity,
  });

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = PianoRollLayoutConstants.velocityLaneBackgroundColor,
    );

    final stemPaint = Paint()
      ..color = PianoRollLayoutConstants.velocityStemColor
      ..strokeWidth = PianoRollLayoutConstants.velocityStemStrokePx;
    final selectedPaint = Paint()
      ..color = PianoRollLayoutConstants.velocitySelectedStemColor
      ..strokeWidth = PianoRollLayoutConstants.velocityStemStrokePx;

    for (final note in slice.visibleNotes) {
      final start = playbackTimingMode == PlaybackTimingMode.raw
          ? note.rawStartTick.value
          : note.quantizedStartTick.value;
      final x = start * pixelsPerTick - scrollXpx;
      if (x < -PianoRollLayoutConstants.velocityStemStrokePx ||
          x > size.width + PianoRollLayoutConstants.velocityStemStrokePx) {
        continue;
      }
      final velocity = note.noteId == previewNoteId && previewVelocity != null
          ? previewVelocity!
          : note.velocity;
      final barHeight = math.max(
        PianoRollLayoutConstants.velocityBarMinHeightPx,
        (velocity / MuseConstants.maxMidiVelocity) * size.height,
      );
      canvas.drawLine(
        Offset(x, size.height),
        Offset(x, size.height - barHeight),
        selectedNoteIds.contains(note.noteId) ? selectedPaint : stemPaint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _VelocityLanePainter oldDelegate) =>
      oldDelegate.pixelsPerTick != pixelsPerTick ||
      oldDelegate.scrollXpx != scrollXpx ||
      oldDelegate.previewNoteId != previewNoteId ||
      oldDelegate.previewVelocity != previewVelocity ||
      oldDelegate.playbackTimingMode != playbackTimingMode ||
      oldDelegate.slice.visibleNotes.length != slice.visibleNotes.length ||
      oldDelegate.selectedNoteIds.length != selectedNoteIds.length;
}

final class _PianoRollTopBar extends StatelessWidget {
  final PianoRollViewportController controller;
  final String activePartName;
  final bool isLoopEditMode;
  final ValueChanged<bool> onToggleLoopEditMode;

  const _PianoRollTopBar({
    required this.controller,
    required this.activePartName,
    required this.isLoopEditMode,
    required this.onToggleLoopEditMode,
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
            Text(
              'Part: $activePartName',
              key: const Key('piano_roll_active_part_label'),
              style: const TextStyle(fontWeight: FontWeight.bold),
            ),
            const SizedBox(width: MusePresentationConstants.standardControlGapPx),
            SegmentedButton<PianoRollToolMode>(
              key: const Key('piano_roll_tool_switcher'),
              segments: const <ButtonSegment<PianoRollToolMode>>[
                ButtonSegment<PianoRollToolMode>(
                  value: PianoRollToolMode.select,
                  label: Text('Select'),
                ),
                ButtonSegment<PianoRollToolMode>(
                  value: PianoRollToolMode.draw,
                  label: Text('Draw'),
                ),
                ButtonSegment<PianoRollToolMode>(
                  value: PianoRollToolMode.erase,
                  label: Text('Erase'),
                ),
                ButtonSegment<PianoRollToolMode>(
                  value: PianoRollToolMode.pan,
                  label: Text('Pan'),
                ),
              ],
              selected: <PianoRollToolMode>{controller.activeTool},
              onSelectionChanged: (selected) {
                if (selected.isNotEmpty) {
                  controller.setToolMode(selected.first);
                }
              },
            ),
            const SizedBox(width: MusePresentationConstants.standardControlGapPx),
            DropdownButton<int>(
              key: const Key('piano_roll_snap_dropdown'),
              value: controller.selectedSnapTicks,
              items: MusePresentationConstants.supportedSubdivisionTicks
                  .map(
                    (ticks) => DropdownMenuItem<int>(
                      value: ticks,
                      child: Text('Snap ${_snapLabel(ticks)}'),
                    ),
                  )
                  .toList(growable: false),
              onChanged: (value) {
                if (value != null) {
                  unawaited(controller.updateProjectSnapTicks(value));
                }
              },
            ),
            const SizedBox(width: MusePresentationConstants.standardControlGapPx),
            FilterChip(
              key: const Key('piano_roll_loop_drag_toggle'),
              label: const Text('Loop Drag'),
              selected: isLoopEditMode,
              onSelected: onToggleLoopEditMode,
            ),
            IconButton(
              key: const Key('piano_roll_hzoom_out'),
              tooltip: 'Horizontal zoom out',
              onPressed: controller.zoomHorizontalOut,
              icon: const Icon(Icons.zoom_out),
            ),
            IconButton(
              key: const Key('piano_roll_hzoom_in'),
              tooltip: 'Horizontal zoom in',
              onPressed: controller.zoomHorizontalIn,
              icon: const Icon(Icons.zoom_in),
            ),
            IconButton(
              key: const Key('piano_roll_vzoom_out'),
              tooltip: 'Vertical zoom out',
              onPressed: controller.zoomVerticalOut,
              icon: const Icon(Icons.unfold_less),
            ),
            IconButton(
              key: const Key('piano_roll_vzoom_in'),
              tooltip: 'Vertical zoom in',
              onPressed: controller.zoomVerticalIn,
              icon: const Icon(Icons.unfold_more),
            ),
            IconButton(
              key: const Key('piano_roll_center_c4'),
              tooltip: 'Center on C4',
              onPressed: () => controller.centerOnPitchMidi(
                PianoRollLayoutConstants.initialScrollCenterPitchMidi,
              ),
              icon: const Icon(Icons.vertical_align_center),
            ),
          ],
        ),
      ),
    );
  }

  static String _snapLabel(int ticks) => switch (ticks) {
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
    _ => '$ticks',
  };
}

final class _PianoRollErrorBanner extends StatelessWidget {
  final Object error;
  final VoidCallback onDismiss;

  const _PianoRollErrorBanner({required this.error, required this.onDismiss});

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
              error.toString(),
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
