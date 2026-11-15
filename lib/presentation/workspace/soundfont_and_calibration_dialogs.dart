/// Layer 5 SoundFont Library and Hardware Latency Calibration dialogs.
library;

import 'dart:async';
import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

import '../../bridge/contracts/engine_constants.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import '../controllers/audio_session_contract.dart';
import '../controllers/project_catalog_controller.dart';
import '../theme/muse_presentation_constants.dart';

/// Opens the [SoundFontLibraryDialog] bound to [catalogController].
Future<void> showSoundFontLibraryDialog({
  required BuildContext context,
  required ProjectCatalogController catalogController,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) =>
      SoundFontLibraryDialog(catalogController: catalogController),
);

/// Opens the [LatencyCalibrationDialog] bound to [catalogController] and
/// [audioSessionController].
Future<void> showLatencyCalibrationDialog({
  required BuildContext context,
  required ProjectCatalogController catalogController,
  required IAudioSessionController audioSessionController,
  ProjectId? targetProjectId,
}) => showDialog<void>(
  context: context,
  builder: (dialogContext) => LatencyCalibrationDialog(
    catalogController: catalogController,
    audioSessionController: audioSessionController,
    targetProjectId: targetProjectId,
  ),
);

/// Dialog listing active CAS SoundFonts, preset banks/programs, `.sf2` import,
/// and active-project-aware soft deletion.
final class SoundFontLibraryDialog extends StatelessWidget {
  static const int _mibFractionDigits = 2;

  final ProjectCatalogController catalogController;

  const SoundFontLibraryDialog({super.key, required this.catalogController});

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: catalogController,
      builder: (context, _) {
        final state = catalogController.state;
        final soundFonts = state.soundFonts;
        final error = state.lastError;
        return AlertDialog(
          title: const Text('SoundFont Library (.sf2)'),
          content: SizedBox(
            width: MusePresentationConstants.dialogMaxWidthPx,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (error != null)
                  Container(
                    key: const Key('soundfont_dialog_error_banner'),
                    padding: const EdgeInsets.all(
                      MusePresentationConstants.shellCardPaddingPx,
                    ),
                    margin: const EdgeInsets.only(
                      bottom: MusePresentationConstants.standardControlGapPx,
                    ),
                    decoration: BoxDecoration(
                      color: MusePresentationConstants
                          .sessionErrorBannerBackground,
                      border: Border.all(
                        color:
                            MusePresentationConstants.sessionErrorBannerBorder,
                      ),
                    ),
                    child: Text(
                      '${error.code.name}: ${error.message}',
                      style: const TextStyle(
                        color:
                            MusePresentationConstants.sessionErrorBannerText,
                      ),
                    ),
                  ),
                Row(
                  children: [
                    ElevatedButton.icon(
                      key: const Key('soundfont_import_button'),
                      onPressed: state.isBusy
                          ? null
                          : () => unawaited(
                              catalogController.importSoundFontFile(),
                            ),
                      icon: const Icon(Icons.library_add),
                      label: const Text('Import .sf2'),
                    ),
                    const Spacer(),
                    if (state.isBusy)
                      const SizedBox(
                        width: MusePresentationConstants.statusIconSizePx,
                        height: MusePresentationConstants.statusIconSizePx,
                        child: CircularProgressIndicator(),
                      ),
                  ],
                ),
                const SizedBox(
                  height: MusePresentationConstants.standardControlGapPx,
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: MusePresentationConstants.dialogListMaxHeightPx,
                  ),
                  child: soundFonts.isEmpty
                      ? const Center(
                          child: Text('No active SoundFonts in library.'),
                        )
                      : ListView.builder(
                          shrinkWrap: true,
                          itemCount: soundFonts.length,
                          itemBuilder: (context, index) {
                            final entry = soundFonts[index];
                            final sizeMib =
                                (entry.byteSize / MuseConstants.bytesPerMib)
                                    .toStringAsFixed(_mibFractionDigits);
                            final shaLen = math.min(
                              MusePresentationConstants.sha256PrefixDisplayLength,
                              entry.blobSha256.value.length,
                            );
                            final shaPrefix = entry.blobSha256.value.substring(
                              MusePresentationConstants.initialTick,
                              shaLen,
                            );
                            return ExpansionTile(
                              key: Key('soundfont_entry_${entry.sfId.value}'),
                              title: Text(entry.name),
                              subtitle: Text(
                                '$sizeMib MiB | sha256:$shaPrefix | ${entry.presets.length} presets',
                              ),
                              trailing: IconButton(
                                key: Key(
                                  'soundfont_delete_${entry.sfId.value}',
                                ),
                                tooltip: 'Delete SoundFont',
                                icon: const Icon(Icons.delete_outline),
                                onPressed: state.isBusy
                                    ? null
                                    : () => unawaited(
                                        catalogController.deleteSoundFont(
                                          entry.sfId,
                                        ),
                                      ),
                              ),
                              children: entry.presets
                                  .map(
                                    (preset) => ListTile(
                                      dense: true,
                                      title: Text(preset.presetName),
                                      subtitle: Text(
                                        'Bank ${preset.bankNum} : Program ${preset.programNum}',
                                      ),
                                    ),
                                  )
                                  .toList(growable: false),
                            );
                          },
                        ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              key: const Key('soundfont_dialog_close_button'),
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Close'),
            ),
          ],
        );
      },
    );
  }
}

/// Dialog reading live hardware info from [IAudioSessionController],
/// loading existing [LatencyCalibrationProfile], and saving sample-rate-bounded
/// round-trip calibration offsets with take realignment.
final class LatencyCalibrationDialog extends StatefulWidget {
  final ProjectCatalogController catalogController;
  final IAudioSessionController audioSessionController;
  final ProjectId? targetProjectId;

  const LatencyCalibrationDialog({
    super.key,
    required this.catalogController,
    required this.audioSessionController,
    this.targetProjectId,
  });

  @override
  State<LatencyCalibrationDialog> createState() =>
      _LatencyCalibrationDialogState();
}

final class _LatencyCalibrationDialogState extends State<LatencyCalibrationDialog> {
  static const int _msPerSecondDoubleFactor =
      MusePresentationConstants.millisecondsPerSecond;

  int _offsetFrames = MusePresentationConstants.initialTick;
  bool _hasLoadedProfile = false;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    unawaited(_loadCurrentProfile());
  }

  Future<void> _loadCurrentProfile() async {
    final result = await widget.catalogController
        .loadCalibrationProfileForCurrentHardware();
    if (!mounted) {
      return;
    }
    if (result case Ok<LatencyCalibrationProfile?>(:final value)) {
      setState(() {
        _hasLoadedProfile = true;
        _offsetFrames =
            value?.calibrationOffsetFrames ??
            MusePresentationConstants.initialTick;
      });
    } else {
      setState(() {
        _hasLoadedProfile = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<AudioSessionStatus>(
      valueListenable: widget.audioSessionController.audioSessionStatus,
      builder: (context, sessionStatus, _) {
        return AnimatedBuilder(
          animation: widget.catalogController,
          builder: (context, _) {
            final hw = sessionStatus.hardwareInfo;
            final isReady =
                sessionStatus.phase == AudioSessionPhase.ready && hw != null;
            final maxOffsetFrames = hw == null
                ? MusePresentationConstants.initialTick
                : (MusePresentationConstants.calibrationMaxOffsetMs *
                          hw.sampleRate) ~/
                      MusePresentationConstants.millisecondsPerSecond;
            final stepFrames = hw == null
                ? MusePresentationConstants.minCalibrationStepFrames
                : math.max(
                    MusePresentationConstants.minCalibrationStepFrames,
                    (MusePresentationConstants.calibrationStepMs *
                            hw.sampleRate) ~/
                        MusePresentationConstants.millisecondsPerSecond,
                  );
            final clampedOffset = maxOffsetFrames == 0
                ? MusePresentationConstants.initialTick
                : _offsetFrames.clamp(-maxOffsetFrames, maxOffsetFrames);
            final offsetMsText = hw == null
                ? '0.0 ms'
                : ((clampedOffset * _msPerSecondDoubleFactor) / hw.sampleRate)
                      .toStringAsFixed(
                        MusePresentationConstants.decimalPrecisionOneDigit
                            .toInt(),
                      );
            final error = widget.catalogController.state.lastError;
            final canSave = isReady && !_isSaving;

            return AlertDialog(
              title: const Text('Audio Latency Calibration'),
              content: SizedBox(
                width: MusePresentationConstants.dialogMaxWidthPx,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (!isReady)
                      Container(
                        key: const Key('calibration_unattached_warning'),
                        padding: const EdgeInsets.all(
                          MusePresentationConstants.shellCardPaddingPx,
                        ),
                        decoration: BoxDecoration(
                          color: MusePresentationConstants
                              .sessionErrorBannerBackground,
                          border: Border.all(
                            color: MusePresentationConstants
                                .sessionErrorBannerBorder,
                          ),
                        ),
                        child: Text(
                          sessionStatus.error != null
                              ? '${sessionStatus.error!.code.name}: ${sessionStatus.error!.message}'
                              : 'Audio device is not initialized (${sessionStatus.phase.name}). Initialize audio before calibrating.',
                          style: const TextStyle(
                            color: MusePresentationConstants
                                .sessionErrorBannerText,
                          ),
                        ),
                      ),
                    if (isReady) ...[
                      Text(
                        'Device: ${hw.deviceFingerprint}\n'
                        'Sample Rate: ${hw.sampleRate} Hz | '
                        'Out Buffer: ${hw.outputBufferFrames} frames | '
                        'In Buffer: ${hw.inputBufferFrames} frames',
                      ),
                      const SizedBox(
                        height: MusePresentationConstants.standardControlGapPx,
                      ),
                      if (!_hasLoadedProfile)
                        const LinearProgressIndicator()
                      else ...[
                        Text(
                          'Calibration Offset: $clampedOffset frames ($offsetMsText ms)',
                          key: const Key('calibration_offset_readout'),
                        ),
                        if (maxOffsetFrames >
                            MusePresentationConstants.initialTick)
                          Slider(
                            key: const Key('calibration_offset_slider'),
                            value: clampedOffset.toDouble(),
                            min: -maxOffsetFrames.toDouble(),
                            max: maxOffsetFrames.toDouble(),
                            onChanged: (value) => setState(() {
                              _offsetFrames = value.round();
                            }),
                          ),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceBetween,
                          children: [
                            OutlinedButton(
                              key: const Key('calibration_step_down_button'),
                              onPressed: () => setState(() {
                                _offsetFrames = (_offsetFrames - stepFrames)
                                    .clamp(-maxOffsetFrames, maxOffsetFrames);
                              }),
                              child: Text('-$stepFrames frames'),
                            ),
                            TextButton(
                              key: const Key('calibration_reset_button'),
                              onPressed: () => setState(() {
                                _offsetFrames =
                                    MusePresentationConstants.initialTick;
                              }),
                              child: const Text('Reset (0)'),
                            ),
                            OutlinedButton(
                              key: const Key('calibration_step_up_button'),
                              onPressed: () => setState(() {
                                _offsetFrames = (_offsetFrames + stepFrames)
                                    .clamp(-maxOffsetFrames, maxOffsetFrames);
                              }),
                              child: Text('+$stepFrames frames'),
                            ),
                          ],
                        ),
                      ],
                    ],
                    if (error != null) ...[
                      const SizedBox(
                        height: MusePresentationConstants.standardControlGapPx,
                      ),
                      Text(
                        '${error.code.name}: ${error.message}',
                        key: const Key('calibration_error_text'),
                        style: const TextStyle(
                          color:
                              MusePresentationConstants.sessionErrorBannerText,
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: [
                TextButton(
                  key: const Key('calibration_cancel_button'),
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('Cancel'),
                ),
                ElevatedButton(
                  key: const Key('calibration_save_button'),
                  onPressed: canSave
                      ? () async {
                          setState(() => _isSaving = true);
                          final saveResult = await widget.catalogController
                              .saveCalibrationProfileAndRealign(
                                calibrationOffsetFrames: clampedOffset,
                                targetProjectId: widget.targetProjectId,
                              );
                          if (!mounted) {
                            return;
                          }
                          setState(() => _isSaving = false);
                          if (saveResult.isOk && context.mounted) {
                            Navigator.of(context).pop();
                          }
                        }
                      : null,
                  child: const Text('Save & Realign'),
                ),
              ],
            );
          },
        );
      },
    );
  }
}
