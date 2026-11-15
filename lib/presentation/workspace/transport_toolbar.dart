/// Layer 5 DAW + Notation Transport Toolbar with 60 Hz RepaintBoundary meters,
/// digital Bar:Beat:Tick clock, live recording waveform strip, and export controls.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../domain/commands/score_editing_command_bus.dart';
import '../../domain/models/score_models.dart';
import '../../domain/notation/dual_model_score_service.dart';
import '../../domain/timeline/tempo_timeline_calculator.dart';
import '../controllers/audio_session_contract.dart';
import '../controllers/project_catalog_controller.dart';
import '../controllers/transport_and_telemetry_controller.dart';
import '../controllers/workspace_shell_controller.dart';
import '../theme/muse_presentation_constants.dart';
import 'soundfont_and_calibration_dialogs.dart';

/// Top workspace transport bar bound to [WorkspaceShellController],
/// [TransportAndTelemetryController], and [ProjectCatalogController].
final class TransportToolbar extends StatelessWidget {
  final ProjectCatalogController catalogController;
  final WorkspaceShellController workspaceController;
  final TransportAndTelemetryController transportController;
  final IAudioSessionController audioSessionController;
  final ScoreWorkspaceState workspace;

  const TransportToolbar({
    super.key,
    required this.catalogController,
    required this.workspaceController,
    required this.transportController,
    required this.audioSessionController,
    required this.workspace,
  });

  static int _activeUsPerQuarterAt(
    List<TempoEventEntity> tempoEvents,
    Tick tick,
  ) {
    var active = MusePresentationConstants.defaultNewProjectUsPerQuarter;
    var bestTick = -1;
    for (final event in tempoEvents) {
      if (event.tick.value <= tick.value && event.tick.value >= bestTick) {
        bestTick = event.tick.value;
        active = event.usPerQuarter;
      }
    }
    return active;
  }

  static Tick _defaultLoopEndTick({
    required ITempoTimelineCalculator? calc,
    required Tick startTick,
  }) {
    final fallbackEnd = Tick(
      startTick.value +
          MuseConstants.wholeNoteTicks *
              MusePresentationConstants.defaultLoopSpanBars,
    );
    if (calc == null) {
      return fallbackEnd;
    }
    var cursorTick = startTick;
    for (var i = 0; i < MusePresentationConstants.defaultLoopSpanBars; i++) {
      final pos = calc.tickToBarBeatTick(cursorTick);
      cursorTick = Tick(pos.measureStartTick.value + pos.measureDurationTicks);
    }
    return cursorTick;
  }

  @override
  Widget build(BuildContext context) {
    final agg = workspace.aggregate;
    final project = agg.project;

    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        workspaceController,
        transportController,
        catalogController,
      ]),
      builder: (context, _) {
        final shellState = workspaceController.state;
        final currentAgg =
            workspaceController.currentWorkspace?.aggregate ?? agg;
        final activeAlert =
            transportController.activeAlert ??
            shellState.lastError ??
            catalogController.state.lastError;
        final calc = workspaceController
            .buildTimelineCalculatorForActiveWorkspace();
        final tickZeroUsPerQuarter = _activeUsPerQuarterAt(
          currentAgg.tempoEvents,
          const Tick(MusePresentationConstants.initialTick),
        );
        final tickZeroBpm =
            (MusePresentationConstants.microsecondsPerMinute /
                    tickZeroUsPerQuarter)
                .round();
        final exportTargetPartId =
            transportController.armedPartId ?? shellState.selectedPartId;
        AudioTakeEntity? exportableTake;
        ProjectPartEntity? exportablePart;
        if (exportTargetPartId != null) {
          for (final take in currentAgg.audioTakes) {
            if (take.partId == exportTargetPartId) {
              exportableTake = take;
              break;
            }
          }
          for (final part in currentAgg.parts) {
            if (part.partId == exportTargetPartId) {
              exportablePart = part;
              break;
            }
          }
        }

        final loopRange = transportController.loopTickRange;
        final String loopText;
        if (loopRange != null && calc != null) {
          final startMeasure = calc
              .tickToBarBeatTick(loopRange.startTick)
              .measureNumber;
          final inclusiveEndTick =
              loopRange.endTick.value > loopRange.startTick.value
              ? Tick(
                  loopRange.endTick.value -
                      MusePresentationConstants.inclusiveLoopEndTickOffset,
                )
              : loopRange.endTick;
          final endMeasure = calc
              .tickToBarBeatTick(inclusiveEndTick)
              .measureNumber;
          loopText = 'Loop B$startMeasure-B$endMeasure';
        } else {
          loopText = 'Loop';
        }

        return Material(
          elevation: MusePresentationConstants.shellCompactGapPx / 2,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: MusePresentationConstants.shellCardPaddingPx,
                  vertical: MusePresentationConstants.shellCompactGapPx,
                ),
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight:
                          MusePresentationConstants.transportToolbarMinHeightPx,
                    ),
                    child: Row(
                      children: [
                        IconButton(
                          key: const Key('transport_back_to_catalog'),
                          tooltip: 'Back to Project Catalog',
                          onPressed: () =>
                              unawaited(workspaceController.closeProject()),
                          icon: const Icon(Icons.arrow_back),
                        ),
                        TextButton.icon(
                          key: const Key('transport_project_title_button'),
                          onPressed: () =>
                              unawaited(_showEditTitleDialog(context, project)),
                          icon: const Icon(Icons.edit_note),
                          label: ConstrainedBox(
                            constraints: const BoxConstraints(
                              maxWidth:
                                  MusePresentationConstants.mixerSliderWidthPx,
                            ),
                            child: Text(
                              project.title,
                              maxLines: MusePresentationConstants.titleMaxLines,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                        const VerticalDivider(),
                        IconButton(
                          key: const Key('transport_rewind_button'),
                          tooltip: 'Seek to Start (Tick 0)',
                          onPressed: () => transportController.seekToTick(
                            const Tick(MusePresentationConstants.initialTick),
                          ),
                          icon: const Icon(Icons.skip_previous),
                        ),
                        IconButton(
                          key: const Key('transport_play_button'),
                          tooltip: 'Play',
                          onPressed: () =>
                              unawaited(transportController.play()),
                          icon: Icon(
                            Icons.play_arrow,
                            color: transportController.isPlaying
                                ? MusePresentationConstants.loopActiveColor
                                : null,
                          ),
                        ),
                        IconButton(
                          key: const Key('transport_pause_button'),
                          tooltip: 'Pause',
                          onPressed: transportController.pause,
                          icon: const Icon(Icons.pause),
                        ),
                        IconButton(
                          key: const Key('transport_stop_button'),
                          tooltip: 'Stop & Reset to Start',
                          onPressed: transportController.stop,
                          icon: const Icon(Icons.stop),
                        ),
                        IconButton(
                          key: const Key('transport_record_button'),
                          tooltip: transportController.isRecording
                              ? 'Stop & Commit Recording'
                              : 'Record Armed Part',
                          onPressed: () => unawaited(
                            transportController.isRecording
                                ? transportController.stopAndCommitRecording()
                                : transportController.startRecordingOnArmedPart(
                                    punchInTick:
                                        transportController.playheadTick.value,
                                  ),
                          ),
                          icon: Icon(
                            transportController.isRecording
                                ? Icons.stop_circle
                                : Icons.fiber_manual_record,
                            color: transportController.isRecording
                                ? MusePresentationConstants.recordingActiveColor
                                : null,
                          ),
                        ),
                        FilterChip(
                          key: const Key('transport_loop_toggle'),
                          label: Text(loopText),
                          selected: transportController.isLoopEnabled,
                          onSelected: (selected) {
                            final existing =
                                transportController.loopTickRange;
                            final startTick =
                                existing?.startTick ??
                                const Tick(
                                  MusePresentationConstants.initialTick,
                                );
                            final latestCalc = workspaceController
                                .buildTimelineCalculatorForActiveWorkspace();
                            final fallbackEnd = _defaultLoopEndTick(
                              calc: latestCalc,
                              startTick: startTick,
                            );
                            final endTick = existing != null &&
                                    existing.endTick.value > startTick.value
                                ? existing.endTick
                                : fallbackEnd;
                            transportController.setLoopTickRange(
                              enabled: selected,
                              startTick: startTick,
                              endTick: endTick,
                            );
                          },
                        ),
                        const SizedBox(
                          width: MusePresentationConstants.standardControlGapPx,
                        ),
                        FilterChip(
                          key: const Key('transport_count_in_toggle'),
                          label: const Text('Count-In'),
                          selected: transportController.countInEnabled,
                          onSelected: transportController.setCountInEnabled,
                        ),
                        const SizedBox(
                          width: MusePresentationConstants.standardControlGapPx,
                        ),
                        ValueListenableBuilder<Tick>(
                          valueListenable: transportController.playheadTick,
                          builder: (context, currentTick, _) {
                            final activeUsPerQuarter = _activeUsPerQuarterAt(
                              currentAgg.tempoEvents,
                              currentTick,
                            );
                            final currentBpm =
                                (MusePresentationConstants
                                            .microsecondsPerMinute /
                                        activeUsPerQuarter)
                                    .round();
                            return ActionChip(
                              key: const Key('transport_tempo_badge'),
                              label: Text('$currentBpm BPM'),
                              onPressed: () => unawaited(
                                _showEditTempoDialog(context, tickZeroBpm),
                              ),
                            );
                          },
                        ),
                        const SizedBox(
                          width: MusePresentationConstants.standardControlGapPx,
                        ),
                        RepaintBoundary(
                          child: SizedBox(
                            width: MusePresentationConstants.clockFieldWidthPx,
                            child: ValueListenableBuilder<Tick>(
                              key: const Key('transport_digital_clock'),
                              valueListenable: transportController.playheadTick,
                              builder: (context, tick, _) {
                                final activeCalc = workspaceController
                                    .buildTimelineCalculatorForActiveWorkspace();
                                if (activeCalc == null) {
                                  return const Text('Bar - : - : -');
                                }
                                final pos = activeCalc.tickToBarBeatTick(tick);
                                final beatNumber =
                                    pos.beatIndex +
                                    MusePresentationConstants
                                        .beatDisplayIndexOffset;
                                return Text(
                                  'Bar ${pos.measureNumber} : Beat $beatNumber : ${pos.tickInBeat}',
                                  maxLines:
                                      MusePresentationConstants.titleMaxLines,
                                  overflow: TextOverflow.ellipsis,
                                );
                              },
                            ),
                          ),
                        ),
                        const VerticalDivider(),
                        IconButton(
                          key: const Key('transport_undo_button'),
                          tooltip: 'Undo',
                          onPressed: shellState.canUndo
                              ? () => unawaited(workspaceController.undo())
                              : null,
                          icon: const Icon(Icons.undo),
                        ),
                        IconButton(
                          key: const Key('transport_redo_button'),
                          tooltip: 'Redo',
                          onPressed: shellState.canRedo
                              ? () => unawaited(workspaceController.redo())
                              : null,
                          icon: const Icon(Icons.redo),
                        ),
                        const SizedBox(
                          width: MusePresentationConstants.standardControlGapPx,
                        ),
                        DropdownButton<PlaybackTimingMode>(
                          key: const Key('transport_timing_mode_dropdown'),
                          value: project.playbackTimingMode,
                          items: PlaybackTimingMode.values
                              .map(
                                (mode) => DropdownMenuItem<PlaybackTimingMode>(
                                  value: mode,
                                  child: Text('Timing: ${mode.name}'),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (mode) {
                            if (mode != null) {
                              unawaited(
                                workspaceController.updateProjectSettings(
                                  playbackTimingMode: mode,
                                ),
                              );
                            }
                          },
                        ),
                        const SizedBox(
                          width: MusePresentationConstants.standardControlGapPx,
                        ),
                        DropdownButton<int>(
                          key: const Key('transport_snap_dropdown'),
                          value:
                              MusePresentationConstants.supportedSubdivisionTicks
                                  .contains(project.gridSnapTicks)
                              ? project.gridSnapTicks
                              : MusePresentationConstants.defaultGridSnapTicks,
                          items: MusePresentationConstants
                              .supportedSubdivisionTicks
                              .map(
                                (ticks) => DropdownMenuItem<int>(
                                  value: ticks,
                                  child: Text(
                                    'Snap ${MusePresentationConstants.formatSubdivisionLabel(ticks)}',
                                  ),
                                ),
                              )
                              .toList(growable: false),
                          onChanged: (ticks) {
                            if (ticks != null) {
                              unawaited(
                                workspaceController.updateProjectSettings(
                                  gridSnapTicks: ticks,
                                ),
                              );
                            }
                          },
                        ),
                        const SizedBox(
                          width: MusePresentationConstants.standardControlGapPx,
                        ),
                        ActionChip(
                          key: const Key('transport_pickup_badge'),
                          label: Text('Pickup ${project.pickupTicks}t'),
                          onPressed: () => unawaited(
                            _showEditPickupDialog(
                              context,
                              project.pickupTicks,
                            ),
                          ),
                        ),
                        const SizedBox(
                          width: MusePresentationConstants.standardControlGapPx,
                        ),
                        const Text('Mon'),
                        SizedBox(
                          width: MusePresentationConstants.meterBarWidthPx * 1.4,
                          child: Slider(
                            key: const Key('transport_monitor_gain_slider'),
                            value: transportController.monitorGainLinear,
                            min: TelemetryConstants.minLinearAmplitude,
                            max: TelemetryConstants.monitorGainMaxLinear,
                            divisions:
                                MusePresentationConstants.monitorGainDivisions,
                            onChanged: transportController.setMonitorGain,
                          ),
                        ),
                        RepaintBoundary(
                          child: ValueListenableBuilder<TelemetryMeterSnapshot>(
                            key: const Key('transport_meters_readout'),
                            valueListenable: transportController.meters,
                            builder: (context, snapshot, _) {
                              return Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  _MeterPill(
                                    label: 'L',
                                    peak: snapshot.outputPeakL,
                                    rms: snapshot.outputRmsL,
                                  ),
                                  const SizedBox(
                                    width: MusePresentationConstants
                                        .shellCompactGapPx,
                                  ),
                                  _MeterPill(
                                    label: 'R',
                                    peak: snapshot.outputPeakR,
                                    rms: snapshot.outputRmsR,
                                  ),
                                  const SizedBox(
                                    width: MusePresentationConstants
                                        .shellCompactGapPx,
                                  ),
                                  _MeterPill(
                                    label: 'In',
                                    peak: snapshot.inputPeak,
                                    rms: snapshot.inputRms,
                                  ),
                                ],
                              );
                            },
                          ),
                        ),
                        const SizedBox(
                          width: MusePresentationConstants.standardControlGapPx,
                        ),
                        RepaintBoundary(
                          child: ValueListenableBuilder<
                            List<RecordingWaveformSample>
                          >(
                            key: const Key('transport_live_waveform'),
                            valueListenable:
                                transportController.liveRecordingWaveform,
                            builder: (context, samples, _) {
                              return SizedBox(
                                width: MusePresentationConstants
                                    .waveformStripWidthPx,
                                height: MusePresentationConstants
                                    .waveformStripHeightPx,
                                child: CustomPaint(
                                  painter: _LiveWaveformPainter(samples),
                                ),
                              );
                            },
                          ),
                        ),
                        const VerticalDivider(),
                        TextButton(
                          key: const Key('transport_export_musicxml_button'),
                          onPressed: () => unawaited(
                            catalogController.exportProjectToMusicXml(
                              projectId: project.projectId,
                              compressAsMxl: false,
                            ),
                          ),
                          child: const Text('Export .musicxml'),
                        ),
                        TextButton(
                          key: const Key('transport_export_mxl_button'),
                          onPressed: () => unawaited(
                            catalogController.exportProjectToMusicXml(
                              projectId: project.projectId,
                              compressAsMxl: true,
                            ),
                          ),
                          child: const Text('Export .mxl'),
                        ),
                        TextButton(
                          key: const Key('transport_export_wav_button'),
                          onPressed:
                              exportableTake != null && exportablePart != null
                              ? () => unawaited(
                                  catalogController.exportRecordedTakeToWav(
                                    take: exportableTake!,
                                    partName: exportablePart!.name,
                                  ),
                                )
                              : null,
                          child: const Text('Export WAV'),
                        ),
                        IconButton(
                          key: const Key('transport_soundfonts_button'),
                          tooltip: 'SoundFonts Library',
                          onPressed: () => unawaited(
                            showSoundFontLibraryDialog(
                              context: context,
                              catalogController: catalogController,
                            ),
                          ),
                          icon: const Icon(Icons.library_music),
                        ),
                        IconButton(
                          key: const Key('transport_calibration_button'),
                          tooltip: 'Audio Latency Calibration',
                          onPressed: () => unawaited(
                            showLatencyCalibrationDialog(
                              context: context,
                              catalogController: catalogController,
                              audioSessionController: audioSessionController,
                              targetProjectId: project.projectId,
                            ),
                          ),
                          icon: const Icon(Icons.tune),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
              if (activeAlert != null)
                Container(
                  key: const Key('transport_alert_banner'),
                  padding: const EdgeInsets.symmetric(
                    horizontal: MusePresentationConstants.shellCardPaddingPx,
                    vertical: MusePresentationConstants.shellCompactGapPx,
                  ),
                  decoration: const BoxDecoration(
                    color: MusePresentationConstants.sessionErrorBannerBackground,
                    border: Border(
                      top: BorderSide(
                        color:
                            MusePresentationConstants.sessionErrorBannerBorder,
                      ),
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(
                        Icons.error_outline,
                        color: MusePresentationConstants.sessionErrorBannerText,
                        size: MusePresentationConstants.statusIconSizePx,
                      ),
                      const SizedBox(
                        width: MusePresentationConstants.standardControlGapPx,
                      ),
                      Expanded(
                        child: Text(
                          '${activeAlert.code.name}: ${activeAlert.message}',
                          maxLines:
                              MusePresentationConstants.errorMessageMaxLines,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: MusePresentationConstants
                                .sessionErrorBannerText,
                          ),
                        ),
                      ),
                      TextButton(
                        key: const Key('transport_alert_dismiss_button'),
                        onPressed: transportController.dismissTelemetryAlert,
                        child: const Text('Dismiss'),
                      ),
                    ],
                  ),
                ),
            ],
          ),
        );
      },
    );
  }

  Future<void> _showEditTitleDialog(
    BuildContext context,
    ProjectSummary project,
  ) async {
    final title = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: 'Project Title',
        inputKey: const Key('transport_title_input'),
        initialValue: project.title,
        labelText: 'Title',
        confirmLabel: 'Save',
      ),
    );
    if (title != null && title.isNotEmpty) {
      await workspaceController.updateProjectSettings(title: title);
    }
  }

  Future<void> _showEditTempoDialog(
    BuildContext context,
    int currentBpm,
  ) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: 'Set Tempo at Tick 0',
        inputKey: const Key('transport_tempo_input'),
        initialValue: currentBpm.toString(),
        labelText:
            'BPM (${TelemetryConstants.bpmMinValid}..${TelemetryConstants.bpmMaxValid})',
        keyboardType: TextInputType.number,
        confirmLabel: 'Apply',
        canSubmit: (value) {
          final bpm = int.tryParse(value);
          return bpm != null &&
              bpm >= TelemetryConstants.bpmMinValid &&
              bpm <= TelemetryConstants.bpmMaxValid;
        },
      ),
    );
    final bpm = raw == null ? null : int.tryParse(raw);
    if (bpm == null) {
      return;
    }
    final active = workspaceController.currentWorkspace;
    if (active == null) {
      return;
    }
    TempoEventId? existingId;
    for (final t in active.aggregate.tempoEvents) {
      if (t.tick.value == MusePresentationConstants.initialTick) {
        existingId = t.tempoEventId;
        break;
      }
    }
    if (existingId == null) {
      return;
    }
    final usPerQuarter = MusePresentationConstants.microsecondsPerMinute ~/ bpm;
    final nowMs = DateTime.now().toUtc().millisecondsSinceEpoch;
    await workspaceController.executeScoreCommand(
      UpsertTempoEventCommand(
        TempoEventEntity(
          tempoEventId: existingId,
          projectId: active.aggregate.project.projectId,
          tick: const Tick(MusePresentationConstants.initialTick),
          usPerQuarter: usPerQuarter,
          updatedAtMs: nowMs,
        ),
      ),
    );
  }

  Future<void> _showEditPickupDialog(
    BuildContext context,
    int currentPickupTicks,
  ) async {
    final raw = await showDialog<String>(
      context: context,
      builder: (_) => _TextPromptDialog(
        title: 'Pickup Measure (Anacrusis) Ticks',
        inputKey: const Key('transport_pickup_input'),
        initialValue: currentPickupTicks.toString(),
        labelText: 'Pickup Ticks (>= 0, 960 = 1 quarter)',
        keyboardType: TextInputType.number,
        confirmLabel: 'Apply',
        canSubmit: (value) {
          final parsed = int.tryParse(value);
          return parsed != null &&
              parsed >= MusePresentationConstants.initialTick;
        },
      ),
    );
    final parsed = raw == null ? null : int.tryParse(raw);
    if (parsed != null) {
      await workspaceController.updateProjectSettings(pickupTicks: parsed);
    }
  }
}

final class _TextPromptDialog extends StatefulWidget {
  final String title;
  final Key inputKey;
  final String initialValue;
  final String labelText;
  final TextInputType? keyboardType;
  final String confirmLabel;
  final bool Function(String trimmedValue)? canSubmit;

  const _TextPromptDialog({
    required this.title,
    required this.inputKey,
    required this.initialValue,
    required this.labelText,
    required this.confirmLabel,
    this.keyboardType,
    this.canSubmit,
  });

  @override
  State<_TextPromptDialog> createState() => _TextPromptDialogState();
}

final class _TextPromptDialogState extends State<_TextPromptDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialValue);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: TextField(
        key: widget.inputKey,
        controller: _controller,
        keyboardType: widget.keyboardType,
        decoration: InputDecoration(labelText: widget.labelText),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          onPressed: () {
            final value = _controller.text.trim();
            if (widget.canSubmit != null && !widget.canSubmit!(value)) {
              return;
            }
            Navigator.of(context).pop(value);
          },
          child: Text(widget.confirmLabel),
        ),
      ],
    );
  }
}

final class _MeterPill extends StatelessWidget {
  final String label;
  final double peak;
  final double rms;

  const _MeterPill({
    required this.label,
    required this.peak,
    required this.rms,
  });

  @override
  Widget build(BuildContext context) {
    final clampedPeak = peak.clamp(
      TelemetryConstants.minLinearAmplitude,
      TelemetryConstants.maxLinearAmplitude,
    );
    final clampedRms = rms.clamp(
      TelemetryConstants.minLinearAmplitude,
      TelemetryConstants.maxLinearAmplitude,
    );
    final Color barColor;
    if (clampedPeak >= TelemetryConstants.meterClipThresholdLinear) {
      barColor = MusePresentationConstants.meterClipColor;
    } else if (clampedPeak >= TelemetryConstants.meterWarnThresholdLinear) {
      barColor = MusePresentationConstants.meterWarnColor;
    } else {
      barColor = MusePresentationConstants.meterNormalColor;
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: Theme.of(context).textTheme.labelSmall),
        Container(
          width: MusePresentationConstants.meterBarWidthPx,
          height: TelemetryConstants.meterHeightPx,
          color: MusePresentationConstants.meterTrackColor,
          child: FractionallySizedBox(
            alignment: Alignment.centerLeft,
            widthFactor: math.max(clampedPeak, clampedRms),
            child: Container(color: barColor),
          ),
        ),
      ],
    );
  }
}

final class _LiveWaveformPainter extends CustomPainter {
  final List<RecordingWaveformSample> samples;

  const _LiveWaveformPainter(this.samples);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Offset.zero & size,
      Paint()..color = MusePresentationConstants.meterTrackColor,
    );
    if (samples.isEmpty ||
        size.width <= MusePresentationConstants.zeroAmplitude ||
        size.height <= MusePresentationConstants.zeroAmplitude) {
      return;
    }
    final paint = Paint()
      ..color = MusePresentationConstants.waveformActiveColor
      ..strokeWidth = MusePresentationConstants.waveformBarStrokePx;
    final centerY = size.height / 2.0;
    final count = samples.length;
    for (var i = 0; i < count; i++) {
      final x = (i / math.max(1, count - 1)) * size.width;
      final amp = samples[i].inputPeak.clamp(
        TelemetryConstants.minLinearAmplitude,
        TelemetryConstants.maxLinearAmplitude,
      );
      final halfBar = math.max(
        MusePresentationConstants.statusBadgeBorderWidthPx,
        amp * centerY,
      );
      canvas.drawLine(
        Offset(x, centerY - halfBar),
        Offset(x, centerY + halfBar),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _LiveWaveformPainter oldDelegate) =>
      oldDelegate.samples != samples;
}
