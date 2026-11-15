/// Layer 5 Part Mixer Sidebar with reorderable parts, record-arm, M/S/Gain/Pan,
/// SoundFont/Preset routing, recorded audio take badges, and Add Part dialog.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../bridge/contracts/audio_bridge_contracts.dart';
import '../../bridge/contracts/ids_and_units.dart';
import '../../domain/models/score_models.dart';
import '../../domain/notation/crisp_score_mapper.dart';
import '../../domain/notation/dual_model_score_service.dart';
import '../controllers/project_catalog_controller.dart';
import '../controllers/transport_and_telemetry_controller.dart';
import '../controllers/workspace_shell_controller.dart';
import '../theme/muse_presentation_constants.dart';

/// Vertical part strip list, mixer channel controls, and SoundFont patch router.
final class PartMixerSidebar extends StatefulWidget {
  final ProjectCatalogController catalogController;
  final WorkspaceShellController workspaceController;
  final TransportAndTelemetryController transportController;
  final ScoreWorkspaceState workspace;

  const PartMixerSidebar({
    super.key,
    required this.catalogController,
    required this.workspaceController,
    required this.transportController,
    required this.workspace,
  });

  @override
  State<PartMixerSidebar> createState() => _PartMixerSidebarState();
}

final class _PartMixerSidebarState extends State<PartMixerSidebar> {
  final Map<PartId, double> _draftGains = <PartId, double>{};
  final Map<PartId, double> _draftPans = <PartId, double>{};
  List<PartId>? _pendingOrderedPartIds;
  int _reorderEpoch = 0;

  static List<ProjectPartEntity> _sortPartsByOrder(
    List<ProjectPartEntity> parts,
  ) {
    final sorted = List<ProjectPartEntity>.from(parts)
      ..sort((a, b) {
        final byOrder = a.sortOrder.compareTo(b.sortOrder);
        return byOrder != 0 ? byOrder : a.partId.value.compareTo(b.partId.value);
      });
    return sorted;
  }

  List<ProjectPartEntity> _applyPendingOrder(
    List<ProjectPartEntity> sortedParts,
  ) {
    final pending = _pendingOrderedPartIds;
    if (pending == null || pending.length != sortedParts.length) {
      return sortedParts;
    }
    final byId = <PartId, ProjectPartEntity>{
      for (final part in sortedParts) part.partId: part,
    };
    final ordered = <ProjectPartEntity>[];
    for (final partId in pending) {
      final part = byId[partId];
      if (part == null) {
        return sortedParts;
      }
      ordered.add(part);
    }
    return ordered;
  }

  Future<void> _commitReorder(List<PartId> orderedPartIds, int epoch) async {
    try {
      await widget.workspaceController.reorderParts(orderedPartIds);
    } finally {
      if (mounted && _reorderEpoch == epoch) {
        setState(() {
          _pendingOrderedPartIds = null;
        });
      }
    }
  }

  static ProjectPartEntity _copyPartWith(
    ProjectPartEntity source, {
    SoundFontId? sfId,
    bool keepExistingSfId = true,
    int? bankNum,
    int? programNum,
    double? gainDb,
    double? pan,
    bool? isMuted,
    bool? isSolo,
    required int nowEpochMs,
  }) => ProjectPartEntity(
    partId: source.partId,
    projectId: source.projectId,
    musicXmlPartId: source.musicXmlPartId,
    sortOrder: source.sortOrder,
    name: source.name,
    stavesCount: source.stavesCount,
    midiChannel: source.midiChannel,
    sfId: keepExistingSfId ? source.sfId : sfId,
    bankNum: bankNum ?? source.bankNum,
    programNum: programNum ?? source.programNum,
    gainDb: gainDb ?? source.gainDb,
    pan: pan ?? source.pan,
    isMuted: isMuted ?? source.isMuted,
    isSolo: isSolo ?? source.isSolo,
    updatedAtMs: nowEpochMs,
  );

  static String _presetKey(int bankNum, int programNum) => '$bankNum:$programNum';

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        widget.workspaceController,
        widget.transportController,
        widget.catalogController,
      ]),
      builder: (context, _) {
        final liveWorkspace =
            widget.workspaceController.workspace ?? widget.workspace;
        final agg = liveWorkspace.aggregate;
        final parts = _applyPendingOrder(_sortPartsByOrder(agg.parts));
        final selectedPartId = widget.workspaceController.state.selectedPartId;
        final armedPartId = widget.transportController.armedPartId;
        final soundFonts = widget.catalogController.state.soundFonts;
        final sfById = {for (final sf in soundFonts) sf.sfId: sf};
        final takesByPartId = {for (final t in agg.audioTakes) t.partId: t};

        return Container(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: Theme.of(context).dividerColor),
            ),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.all(
                  MusePresentationConstants.shellCardPaddingPx,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(
                        'Parts & Mixer (${parts.length})',
                        style: Theme.of(context).textTheme.titleMedium,
                        maxLines: MusePresentationConstants.titleMaxLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              const Divider(height: MusePresentationConstants.statusBadgeBorderWidthPx),
              Expanded(
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: parts.length,
                  onReorderItem: (oldIndex, newIndex) {
                    if (oldIndex < 0 ||
                        oldIndex >= parts.length ||
                        newIndex < 0 ||
                        newIndex >= parts.length ||
                        oldIndex == newIndex) {
                      return;
                    }
                    final reordered = List<PartId>.from(
                      parts.map((p) => p.partId),
                    );
                    final moved = reordered.removeAt(oldIndex);
                    reordered.insert(newIndex, moved);
                    final epoch = ++_reorderEpoch;
                    setState(() {
                      _pendingOrderedPartIds = reordered;
                    });
                    unawaited(_commitReorder(reordered, epoch));
                  },
                  itemBuilder: (context, index) {
                    final part = parts[index];
                    final isSelected = part.partId == selectedPartId;
                    final isArmed = part.partId == armedPartId;
                    final activeSf = part.sfId == null ? null : sfById[part.sfId];
                    final audioTake = takesByPartId[part.partId];
                    final effectiveGainDb = _draftGains[part.partId] ?? part.gainDb;
                    final effectivePan = _draftPans[part.partId] ?? part.pan;

                    return _buildPartCard(
                      context,
                      index: index,
                      part: part,
                      partsCount: parts.length,
                      isSelected: isSelected,
                      isArmed: isArmed,
                      soundFonts: soundFonts,
                      activeSf: activeSf,
                      audioTake: audioTake,
                      effectiveGainDb: effectiveGainDb,
                      effectivePan: effectivePan,
                    );
                  },
                ),
              ),
              const Divider(height: MusePresentationConstants.statusBadgeBorderWidthPx),
              Padding(
                padding: const EdgeInsets.all(
                  MusePresentationConstants.shellCardPaddingPx,
                ),
                child: ElevatedButton.icon(
                  key: const Key('mixer_add_part_button'),
                  onPressed: () =>
                      unawaited(_showAddPartDialog(context, soundFonts)),
                  icon: const Icon(Icons.add),
                  label: const Text('+ Add Part'),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildPartCard(
    BuildContext context, {
    required int index,
    required ProjectPartEntity part,
    required int partsCount,
    required bool isSelected,
    required bool isArmed,
    required List<SoundFontCatalogEntry> soundFonts,
    required SoundFontCatalogEntry? activeSf,
    required AudioTakeEntity? audioTake,
    required double effectiveGainDb,
    required double effectivePan,
  }) {
    final presetOptions = activeSf?.presets ?? const <SoundFontPresetInfo>[];
    final currentPresetKey = _presetKey(part.bankNum, part.programNum);
    final hasMatchingPreset = presetOptions.any(
      (preset) =>
          _presetKey(preset.bankNum, preset.programNum) == currentPresetKey,
    );

    return Card(
      key: ValueKey<String>(part.partId.value),
      color: isSelected ? MusePresentationConstants.partSelectedBackground : null,
      margin: const EdgeInsets.symmetric(
        horizontal: MusePresentationConstants.standardControlGapPx,
        vertical: MusePresentationConstants.shellCompactGapPx,
      ),
      child: InkWell(
        key: Key('mixer_part_select_${part.partId.value}'),
        onTap: () => widget.workspaceController.selectPart(part.partId),
        child: Padding(
          padding: const EdgeInsets.all(
            MusePresentationConstants.shellCardPaddingPx,
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  ReorderableDragStartListener(
                    key: Key('part_drag_handle_${part.partId.value}'),
                    index: index,
                    child: const Padding(
                      padding: EdgeInsets.only(
                        right: MusePresentationConstants.standardControlGapPx,
                      ),
                      child: MouseRegion(
                        cursor: SystemMouseCursors.grab,
                        child: Icon(Icons.drag_handle),
                      ),
                    ),
                  ),
                  Expanded(
                    child: Text(
                      '${part.name} (Ch ${part.midiChannel + MusePresentationConstants.beatDisplayIndexOffset})',
                      maxLines: MusePresentationConstants.titleMaxLines,
                      overflow: TextOverflow.ellipsis,
                      style: Theme.of(context).textTheme.titleSmall,
                    ),
                  ),
                  IconButton(
                    key: Key('part_arm_${part.partId.value}'),
                    tooltip: isArmed ? 'Disarm Recording' : 'Arm for Recording',
                    onPressed: () => widget.transportController
                        .togglePartArmForRecording(part.partId),
                    icon: Icon(
                      Icons.fiber_manual_record,
                      color: isArmed
                          ? MusePresentationConstants.recordingActiveColor
                          : null,
                    ),
                  ),
                  IconButton(
                    key: Key('part_remove_${part.partId.value}'),
                    tooltip: 'Remove Part',
                    onPressed:
                        partsCount >
                            MusePresentationConstants.minimumProjectPartsCount
                        ? () => unawaited(
                            widget.workspaceController.removePart(part.partId),
                          )
                        : null,
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
              Row(
                children: [
                  FilterChip(
                    key: Key('part_mute_${part.partId.value}'),
                    label: const Text('M'),
                    selected: part.isMuted,
                    onSelected: (muted) => unawaited(
                      widget.workspaceController.updatePartMixerOrPatch(
                        _copyPartWith(
                          part,
                          isMuted: muted,
                          nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(
                    width: MusePresentationConstants.shellCompactGapPx,
                  ),
                  FilterChip(
                    key: Key('part_solo_${part.partId.value}'),
                    label: const Text('S'),
                    selected: part.isSolo,
                    onSelected: (solo) => unawaited(
                      widget.workspaceController.updatePartMixerOrPatch(
                        _copyPartWith(
                          part,
                          isSolo: solo,
                          nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: MusePresentationConstants.shellCompactGapPx),
              Text(
                'Gain: ${effectiveGainDb.toStringAsFixed(MusePresentationConstants.decimalPrecisionOneDigit.toInt())} dB',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Slider(
                key: Key('part_gain_${part.partId.value}'),
                value: effectiveGainDb.clamp(
                  MusePresentationConstants.mixerGainMinDb,
                  MusePresentationConstants.mixerGainMaxDb,
                ),
                min: MusePresentationConstants.mixerGainMinDb,
                max: MusePresentationConstants.mixerGainMaxDb,
                divisions: MusePresentationConstants.mixerGainDivisions,
                onChanged: (v) => setState(() => _draftGains[part.partId] = v),
                onChangeEnd: (v) {
                  setState(() => _draftGains.remove(part.partId));
                  unawaited(
                    widget.workspaceController.updatePartMixerOrPatch(
                      _copyPartWith(
                        part,
                        gainDb: v,
                        nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
                      ),
                    ),
                  );
                },
              ),
              Text(
                'Pan: ${effectivePan.toStringAsFixed(MusePresentationConstants.decimalPrecisionOneDigit.toInt())}',
                style: Theme.of(context).textTheme.labelSmall,
              ),
              Slider(
                key: Key('part_pan_${part.partId.value}'),
                value: effectivePan.clamp(
                  MusePresentationConstants.mixerPanMin,
                  MusePresentationConstants.mixerPanMax,
                ),
                min: MusePresentationConstants.mixerPanMin,
                max: MusePresentationConstants.mixerPanMax,
                divisions: MusePresentationConstants.mixerPanDivisions,
                onChanged: (v) => setState(() => _draftPans[part.partId] = v),
                onChangeEnd: (v) {
                  setState(() => _draftPans.remove(part.partId));
                  unawaited(
                    widget.workspaceController.updatePartMixerOrPatch(
                      _copyPartWith(
                        part,
                        pan: v,
                        nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
                      ),
                    ),
                  );
                },
              ),
              if (activeSf == null)
                Padding(
                  padding: const EdgeInsets.only(
                    bottom: MusePresentationConstants.shellCompactGapPx,
                  ),
                  child: Text(
                    'Unassigned SoundFont — select an active SoundFont below to audition.',
                    key: Key('part_unassigned_sf_${part.partId.value}'),
                    style: const TextStyle(
                      color: MusePresentationConstants.sessionErrorBannerText,
                    ),
                  ),
                ),
              DropdownButtonFormField<SoundFontId?>(
                key: Key('part_sf_dropdown_${part.partId.value}'),
                initialValue: activeSf?.sfId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'SoundFont'),
                hint: const Text('Unassigned SoundFont'),
                items: [
                  const DropdownMenuItem<SoundFontId?>(
                    value: null,
                    child: Text('Unassigned SoundFont'),
                  ),
                  ...soundFonts.map(
                    (sf) => DropdownMenuItem<SoundFontId?>(
                      value: sf.sfId,
                      child: Text(
                        sf.name,
                        maxLines: MusePresentationConstants.titleMaxLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (selectedSfId) {
                  if (selectedSfId == null) {
                    unawaited(
                      widget.workspaceController.updatePartMixerOrPatch(
                        _copyPartWith(
                          part,
                          sfId: null,
                          keepExistingSfId: false,
                          nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
                        ),
                      ),
                    );
                    return;
                  }
                  SoundFontCatalogEntry? nextSf;
                  for (final sf in soundFonts) {
                    if (sf.sfId == selectedSfId) {
                      nextSf = sf;
                      break;
                    }
                  }
                  final matchingPreset = nextSf?.presets
                      .where(
                        (p) =>
                            p.bankNum == part.bankNum &&
                            p.programNum == part.programNum,
                      )
                      .firstOrNull;
                  final firstPreset = matchingPreset ?? nextSf?.presets.firstOrNull;
                  unawaited(
                    widget.workspaceController.updatePartMixerOrPatch(
                      _copyPartWith(
                        part,
                        sfId: selectedSfId,
                        keepExistingSfId: false,
                        bankNum: firstPreset?.bankNum ??
                            MusePresentationConstants.defaultPresetBankNum,
                        programNum: firstPreset?.programNum ??
                            MusePresentationConstants.defaultPresetProgramNum,
                        nowEpochMs: DateTime.now().toUtc().millisecondsSinceEpoch,
                      ),
                    ),
                  );
                },
              ),
              const SizedBox(
                height: MusePresentationConstants.standardControlGapPx,
              ),
              DropdownButtonFormField<String>(
                key: Key('part_preset_dropdown_${part.partId.value}'),
                initialValue: hasMatchingPreset ? currentPresetKey : null,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Bank : Program Preset'),
                hint: Text('Bank ${part.bankNum} : Prog ${part.programNum}'),
                items: presetOptions
                    .map(
                      (preset) => DropdownMenuItem<String>(
                        value: _presetKey(preset.bankNum, preset.programNum),
                        child: Text(
                          'B${preset.bankNum}:P${preset.programNum} ${preset.presetName}',
                          maxLines: MusePresentationConstants.titleMaxLines,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    )
                    .toList(growable: false),
                onChanged: activeSf == null
                    ? null
                    : (selectedKey) {
                        if (selectedKey == null) {
                          return;
                        }
                        for (final preset in presetOptions) {
                          if (_presetKey(preset.bankNum, preset.programNum) ==
                              selectedKey) {
                            unawaited(
                              widget.workspaceController.updatePartMixerOrPatch(
                                _copyPartWith(
                                  part,
                                  bankNum: preset.bankNum,
                                  programNum: preset.programNum,
                                  nowEpochMs: DateTime.now()
                                      .toUtc()
                                      .millisecondsSinceEpoch,
                                ),
                              ),
                            );
                            break;
                          }
                        }
                      },
              ),
              if (audioTake != null) ...[
                const SizedBox(
                  height: MusePresentationConstants.standardControlGapPx,
                ),
                Container(
                  key: Key('part_take_badge_${part.partId.value}'),
                  padding: const EdgeInsets.all(
                    MusePresentationConstants.standardControlGapPx,
                  ),
                  decoration: BoxDecoration(
                    color: MusePresentationConstants.readyBadgeBackground,
                    borderRadius: BorderRadius.circular(
                      MusePresentationConstants.shellCompactGapPx,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Audio Take: ${audioTake.durationFrames} frames @ Tick ${audioTake.startTick.value}',
                        style: const TextStyle(
                          color: MusePresentationConstants.readyBadgeText,
                        ),
                      ),
                      Wrap(
                        spacing: MusePresentationConstants.shellCompactGapPx,
                        runSpacing: MusePresentationConstants.shellCompactGapPx,
                        children: [
                          TextButton(
                            key: Key('part_take_export_${part.partId.value}'),
                            onPressed: () => unawaited(
                              widget.catalogController.exportRecordedTakeToWav(
                                take: audioTake,
                                partName: part.name,
                              ),
                            ),
                            child: const Text('Export .wav'),
                          ),
                          TextButton(
                            key: Key('part_take_clear_${part.partId.value}'),
                            onPressed: () => unawaited(
                              widget.workspaceController.clearPartAudio(
                                part.partId,
                              ),
                            ),
                            child: const Text('Clear Take'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showAddPartDialog(
    BuildContext context,
    List<SoundFontCatalogEntry> soundFonts,
  ) async {
    final request = await showDialog<_AddPartRequest>(
      context: context,
      builder: (_) => _AddPartDialog(soundFonts: soundFonts),
    );
    if (request == null) {
      return;
    }
    await widget.workspaceController.addPart(
      name: request.name,
      stavesCount: request.stavesCount,
      sfId: request.sfId,
      bankNum: request.bankNum,
      programNum: request.programNum,
      initialClefSign: request.clefSign,
      initialClefLine: request.clefLine,
      isPercussion: request.isPercussion,
    );
  }
}

@immutable
final class _AddPartRequest {
  final String name;
  final int stavesCount;
  final SoundFontId? sfId;
  final int bankNum;
  final int programNum;
  final ClefSign clefSign;
  final int clefLine;
  final bool isPercussion;

  const _AddPartRequest({
    required this.name,
    required this.stavesCount,
    required this.sfId,
    required this.bankNum,
    required this.programNum,
    required this.clefSign,
    required this.clefLine,
    required this.isPercussion,
  });
}

final class _AddPartDialog extends StatefulWidget {
  final List<SoundFontCatalogEntry> soundFonts;

  const _AddPartDialog({required this.soundFonts});

  @override
  State<_AddPartDialog> createState() => _AddPartDialogState();
}

final class _AddPartDialogState extends State<_AddPartDialog> {
  late final TextEditingController _nameController;
  late int _stavesCount;
  bool _isPercussion = false;
  ClefSign _clefSign = ClefSign.G;
  int _clefLine = CrispScoreMapperConstants.trebleClefLine;
  SoundFontCatalogEntry? _selectedSf;
  SoundFontPresetInfo? _selectedPreset;

  @override
  void initState() {
    super.initState();
    _nameController = TextEditingController(
      text: MusePresentationConstants.defaultInitialPartName,
    );
    _stavesCount = MusePresentationConstants.defaultInitialPartStavesCount;
    _selectedSf = widget.soundFonts.firstOrNull;
    _selectedPreset = _selectedSf?.presets.firstOrNull;
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Add Part'),
      content: SizedBox(
        width: MusePresentationConstants.dialogMaxWidthPx,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('add_part_name_field'),
                controller: _nameController,
                decoration: const InputDecoration(labelText: 'Part Name'),
              ),
              const SizedBox(
                height: MusePresentationConstants.standardControlGapPx,
              ),
              DropdownButtonFormField<int>(
                key: const Key('add_part_staves_dropdown'),
                initialValue: _stavesCount,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Staves'),
                items: const [
                  DropdownMenuItem<int>(
                    value: MusePresentationConstants.singleStaffNumber,
                    child: Text('1 Staff', overflow: TextOverflow.ellipsis),
                  ),
                  DropdownMenuItem<int>(
                    value: MusePresentationConstants.grandStaffStavesCount,
                    child: Text(
                      '2 Staves (Grand Staff)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setState(() => _stavesCount = v);
                  }
                },
              ),
              CheckboxListTile(
                key: const Key('add_part_percussion_checkbox'),
                title: const Text('GM Percussion (Channel 10)'),
                value: _isPercussion,
                onChanged: (v) => setState(() {
                  _isPercussion = v ?? false;
                  if (_isPercussion) {
                    _clefSign = ClefSign.percussion;
                    _clefLine = CrispScoreMapperConstants.altoClefLine;
                  } else if (_clefSign == ClefSign.percussion) {
                    _clefSign = ClefSign.G;
                    _clefLine = CrispScoreMapperConstants.trebleClefLine;
                  }
                }),
              ),
              DropdownButtonFormField<ClefSign>(
                key: const Key('add_part_clef_dropdown'),
                initialValue: _clefSign,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Initial Clef'),
                items: const [
                  DropdownMenuItem<ClefSign>(
                    value: ClefSign.G,
                    child: Text('Treble (G)'),
                  ),
                  DropdownMenuItem<ClefSign>(
                    value: ClefSign.F,
                    child: Text('Bass (F)'),
                  ),
                  DropdownMenuItem<ClefSign>(
                    value: ClefSign.C,
                    child: Text('Alto (C)'),
                  ),
                  DropdownMenuItem<ClefSign>(
                    value: ClefSign.percussion,
                    child: Text('Percussion'),
                  ),
                ],
                onChanged: (v) {
                  if (v != null) {
                    setState(() {
                      _clefSign = v;
                      _clefLine = switch (v) {
                        ClefSign.F => CrispScoreMapperConstants.bassClefLine,
                        ClefSign.C => CrispScoreMapperConstants.altoClefLine,
                        ClefSign.G => CrispScoreMapperConstants.trebleClefLine,
                        _ => CrispScoreMapperConstants.altoClefLine,
                      };
                    });
                  }
                },
              ),
              const SizedBox(
                height: MusePresentationConstants.standardControlGapPx,
              ),
              DropdownButtonFormField<SoundFontCatalogEntry?>(
                key: const Key('add_part_sf_dropdown'),
                initialValue: _selectedSf,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'SoundFont'),
                items: [
                  const DropdownMenuItem<SoundFontCatalogEntry?>(
                    value: null,
                    child: Text(
                      'Unassigned SoundFont',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  ...widget.soundFonts.map(
                    (sf) => DropdownMenuItem<SoundFontCatalogEntry?>(
                      value: sf,
                      child: Text(
                        sf.name,
                        maxLines: MusePresentationConstants.titleMaxLines,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
                onChanged: (sf) => setState(() {
                  _selectedSf = sf;
                  _selectedPreset = sf?.presets.firstOrNull;
                }),
              ),
              if (_selectedSf != null && _selectedSf!.presets.isNotEmpty) ...[
                const SizedBox(
                  height: MusePresentationConstants.standardControlGapPx,
                ),
                DropdownButtonFormField<SoundFontPresetInfo>(
                  key: const Key('add_part_preset_dropdown'),
                  initialValue: _selectedPreset,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Preset'),
                  items: _selectedSf!.presets
                      .map(
                        (p) => DropdownMenuItem<SoundFontPresetInfo>(
                          value: p,
                          child: Text(
                            'B${p.bankNum}:P${p.programNum} ${p.presetName}',
                            maxLines: MusePresentationConstants.titleMaxLines,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (p) => setState(() => _selectedPreset = p),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const Key('add_part_confirm_button'),
          onPressed: () {
            final partName = _nameController.text.trim();
            if (partName.isEmpty) {
              return;
            }
            Navigator.of(context).pop(
              _AddPartRequest(
                name: partName,
                stavesCount: _stavesCount,
                sfId: _selectedSf?.sfId,
                bankNum: _selectedPreset?.bankNum ??
                    MusePresentationConstants.defaultPresetBankNum,
                programNum: _selectedPreset?.programNum ??
                    MusePresentationConstants.defaultPresetProgramNum,
                clefSign: _clefSign,
                clefLine: _clefLine,
                isPercussion: _isPercussion,
              ),
            );
          },
          child: const Text('Add Part'),
        ),
      ],
    );
  }
}
