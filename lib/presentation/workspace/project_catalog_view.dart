/// Layer 5 Project Catalog screen supporting paginated listing, blank score
/// creation, MusicXML/MXL import & export, cache GC, SoundFonts, and calibration.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../bridge/contracts/ids_and_units.dart';
import '../../bridge/contracts/result.dart';
import '../../domain/models/score_models.dart';
import '../../domain/timeline/tempo_timeline_calculator.dart';
import '../controllers/audio_session_contract.dart';
import '../controllers/project_catalog_controller.dart';
import '../controllers/workspace_shell_controller.dart';
import '../theme/muse_presentation_constants.dart';
import 'soundfont_and_calibration_dialogs.dart';

enum _CatalogCardMenuAction {
  rename,
  exportMusicXml,
  exportMxl,
  purgeAudioTakes,
  delete,
}

/// Paginated project browser and library hub when no score workspace is open.
final class ProjectCatalogView extends StatelessWidget {
  static const List<int> _supportedNumerators = <int>[2, 3, 4, 5, 6, 7, 9, 12];

  final ProjectCatalogController catalogController;
  final WorkspaceShellController workspaceController;
  final IAudioSessionController audioSessionController;

  const ProjectCatalogView({
    super.key,
    required this.catalogController,
    required this.workspaceController,
    required this.audioSessionController,
  });

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: Listenable.merge(<Listenable>[
        catalogController,
        workspaceController,
      ]),
      builder: (context, _) {
        final state = catalogController.state;
        final isBusy = state.isBusy || workspaceController.state.isOpening;
        final activeError =
            state.lastError ?? workspaceController.state.lastError;
        final projects = state.projects;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeaderBar(context, state: state, isBusy: isBusy),
            if (activeError != null)
              Container(
                key: const Key('catalog_error_banner'),
                padding: const EdgeInsets.all(
                  MusePresentationConstants.shellCardPaddingPx,
                ),
                margin: const EdgeInsets.symmetric(
                  horizontal: MusePresentationConstants.shellCardPaddingPx,
                  vertical: MusePresentationConstants.shellCompactGapPx,
                ),
                decoration: BoxDecoration(
                  color: MusePresentationConstants.sessionErrorBannerBackground,
                  border: Border.all(
                    color: MusePresentationConstants.sessionErrorBannerBorder,
                  ),
                ),
                child: Text(
                  '${activeError.code.name}: ${activeError.message}',
                  style: const TextStyle(
                    color: MusePresentationConstants.sessionErrorBannerText,
                  ),
                ),
              ),
            Expanded(
              child: projects.isEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(
                          MusePresentationConstants.shellCardPaddingPx,
                        ),
                        child: Text(
                          isBusy
                              ? 'Loading projects...'
                              : 'No projects yet. Create a blank project or import MusicXML/MXL.',
                          textAlign: TextAlign.center,
                        ),
                      ),
                    )
                  : ListView.builder(
                      padding: const EdgeInsets.all(
                        MusePresentationConstants.shellCardPaddingPx,
                      ),
                      itemCount:
                          projects.length + (state.hasMoreProjects ? 1 : 0),
                      itemBuilder: (context, index) {
                        if (index >= projects.length) {
                          return Padding(
                            padding: const EdgeInsets.symmetric(
                              vertical:
                                  MusePresentationConstants.standardControlGapPx,
                            ),
                            child: Center(
                              child: OutlinedButton(
                                key: const Key('catalog_load_more_button'),
                                onPressed: isBusy
                                    ? null
                                    : () => unawaited(
                                        catalogController.loadMoreProjects(),
                                      ),
                                child: const Text('Load More Projects'),
                              ),
                            ),
                          );
                        }
                        final summary = projects[index];
                        return _buildProjectCard(
                          context,
                          summary: summary,
                          isBusy: isBusy,
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildHeaderBar(
    BuildContext context, {
    required ProjectCatalogState state,
    required bool isBusy,
  }) {
    return Material(
      elevation: MusePresentationConstants.shellCompactGapPx / 2,
      child: Padding(
        padding: const EdgeInsets.all(
          MusePresentationConstants.shellCardPaddingPx,
        ),
        child: Wrap(
          spacing: MusePresentationConstants.standardControlGapPx,
          runSpacing: MusePresentationConstants.standardControlGapPx,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: [
            Text(
              'MuseGrid Projects',
              style: Theme.of(context).textTheme.titleLarge,
            ),
            ElevatedButton.icon(
              key: const Key('catalog_new_project_button'),
              onPressed: isBusy
                  ? null
                  : () => unawaited(_showCreateBlankProjectDialog(context)),
              icon: const Icon(Icons.add),
              label: const Text('+ New Project'),
            ),
            OutlinedButton.icon(
              key: const Key('catalog_import_musicxml_button'),
              onPressed: isBusy
                  ? null
                  : () => unawaited(_handleImportMusicXml()),
              icon: const Icon(Icons.file_open),
              label: const Text('Import MusicXML / MXL'),
            ),
            TextButton.icon(
              key: const Key('catalog_soundfonts_button'),
              onPressed: () => unawaited(
                showSoundFontLibraryDialog(
                  context: context,
                  catalogController: catalogController,
                ),
              ),
              icon: const Icon(Icons.library_music),
              label: Text('SoundFonts (${state.soundFonts.length})'),
            ),
            TextButton.icon(
              key: const Key('catalog_calibration_button'),
              onPressed: () => unawaited(
                showLatencyCalibrationDialog(
                  context: context,
                  catalogController: catalogController,
                  audioSessionController: audioSessionController,
                ),
              ),
              icon: const Icon(Icons.tune),
              label: const Text('Audio Calibration'),
            ),
            TextButton.icon(
              key: const Key('catalog_gc_button'),
              onPressed: isBusy
                  ? null
                  : () => unawaited(_handleReclaimStorage(context)),
              icon: const Icon(Icons.cleaning_services),
              label: const Text('Clean Up Cache'),
            ),
            if (isBusy)
              const SizedBox(
                width: MusePresentationConstants.statusIconSizePx,
                height: MusePresentationConstants.statusIconSizePx,
                child: CircularProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildProjectCard(
    BuildContext context, {
    required ProjectSummary summary,
    required bool isBusy,
  }) {
    final snapLabel = MusePresentationConstants.formatSubdivisionLabel(
      summary.gridSnapTicks,
    );
    return Card(
      key: Key('catalog_project_card_${summary.projectId.value}'),
      child: ListTile(
        title: Text(
          summary.title,
          maxLines: MusePresentationConstants.titleMaxLines,
          overflow: TextOverflow.ellipsis,
        ),
        subtitle: Text(
          'Rev ${summary.revision} | ${summary.ppqn} PPQN | Snap $snapLabel | ${summary.playbackTimingMode.name}',
        ),
        onTap: isBusy
            ? null
            : () => unawaited(
                workspaceController.openProject(summary.projectId),
              ),
        trailing: PopupMenuButton<_CatalogCardMenuAction>(
          key: Key('catalog_project_menu_${summary.projectId.value}'),
          enabled: !isBusy,
          onSelected: (action) =>
              unawaited(_handleCardMenuAction(context, summary, action)),
          itemBuilder: (context) => const [
            PopupMenuItem<_CatalogCardMenuAction>(
              value: _CatalogCardMenuAction.rename,
              child: Text('Rename'),
            ),
            PopupMenuItem<_CatalogCardMenuAction>(
              value: _CatalogCardMenuAction.exportMusicXml,
              child: Text('Export .musicxml'),
            ),
            PopupMenuItem<_CatalogCardMenuAction>(
              value: _CatalogCardMenuAction.exportMxl,
              child: Text('Export .mxl'),
            ),
            PopupMenuItem<_CatalogCardMenuAction>(
              value: _CatalogCardMenuAction.purgeAudioTakes,
              child: Text('Purge Recorded Audio Take'),
            ),
            PopupMenuItem<_CatalogCardMenuAction>(
              value: _CatalogCardMenuAction.delete,
              child: Text('Delete Project'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _handleImportMusicXml() async {
    final defaultSfId = catalogController.state.soundFonts.firstOrNull?.sfId;
    final res = await catalogController.importMusicXmlProject(
      defaultSoundFontId: defaultSfId,
    );
    if (res case Ok<ProjectSummary?>(:final value) when value != null) {
      await workspaceController.openProject(value.projectId);
    }
  }

  Future<void> _handleReclaimStorage(BuildContext context) async {
    final res = await catalogController.reclaimUnusedStorageNow();
    if (!context.mounted) {
      return;
    }
    if (res case Ok<int>(:final value)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Reclaimed $value unused CAS blob(s).')),
      );
    }
  }

  Future<void> _handleCardMenuAction(
    BuildContext context,
    ProjectSummary summary,
    _CatalogCardMenuAction action,
  ) async {
    switch (action) {
      case _CatalogCardMenuAction.rename:
        await _showRenameDialog(context, summary);
      case _CatalogCardMenuAction.exportMusicXml:
        await catalogController.exportProjectToMusicXml(
          projectId: summary.projectId,
          compressAsMxl: false,
        );
      case _CatalogCardMenuAction.exportMxl:
        await catalogController.exportProjectToMusicXml(
          projectId: summary.projectId,
          compressAsMxl: true,
        );
      case _CatalogCardMenuAction.purgeAudioTakes:
        await _showPurgeTakesDialog(context, summary);
      case _CatalogCardMenuAction.delete:
        await catalogController.deleteProject(summary.projectId);
    }
  }

  Future<void> _showCreateBlankProjectDialog(BuildContext context) async {
    final request = await showDialog<_CreateBlankProjectRequest>(
      context: context,
      builder: (_) => _CreateBlankProjectDialog(
        soundFonts: catalogController.state.soundFonts,
      ),
    );
    if (request == null) {
      return;
    }
    final createdResult = await catalogController.createBlankProject(
      title: request.title,
      initialSoundFontId: request.soundFontId,
      tempoBpm: request.tempoBpm,
      numerator: request.numerator,
      denominator: request.denominator,
      stavesCount: request.stavesCount,
    );
    if (createdResult case Ok<ProjectSummary>(:final value)) {
      await workspaceController.openProject(value.projectId);
    }
  }

  Future<void> _showRenameDialog(
    BuildContext context,
    ProjectSummary summary,
  ) async {
    final nextTitle = await showDialog<String>(
      context: context,
      builder: (_) => _RenameProjectDialog(initialTitle: summary.title),
    );
    if (nextTitle != null && nextTitle.isNotEmpty) {
      await catalogController.renameProjectInCatalog(
        project: summary,
        newTitle: nextTitle,
      );
    }
  }

  Future<void> _showPurgeTakesDialog(
    BuildContext context,
    ProjectSummary summary,
  ) async {
    final aggResult = await catalogController.inspectProjectAggregateForCatalog(
      summary.projectId,
    );
    if (!context.mounted) {
      return;
    }
    if (aggResult case Err<ProjectWorkspaceAggregate>(:final error)) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('${error.code.name}: ${error.message}')),
      );
      return;
    }
    final agg = (aggResult as Ok<ProjectWorkspaceAggregate>).value;
    final partsById = {for (final p in agg.parts) p.partId: p};

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text('Audio Takes — ${summary.title}'),
        content: SizedBox(
          width: MusePresentationConstants.dialogMaxWidthPx,
          child: agg.audioTakes.isEmpty
              ? const Text('No recorded audio takes exist in this project.')
              : ConstrainedBox(
                  constraints: const BoxConstraints(
                    maxHeight: MusePresentationConstants.dialogListMaxHeightPx,
                  ),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: agg.audioTakes.length,
                    itemBuilder: (context, index) {
                      final take = agg.audioTakes[index];
                      final partName =
                          partsById[take.partId]?.name ?? take.partId.value;
                      return ListTile(
                        title: Text(partName),
                        subtitle: Text(
                          'Start Tick ${take.startTick.value} | ${take.durationFrames} frames @ ${take.sampleRate} Hz',
                        ),
                        trailing: ElevatedButton(
                          key: Key('catalog_purge_take_${take.partId.value}'),
                          onPressed: () async {
                            Navigator.of(dialogContext).pop();
                            await catalogController.purgePartAudioTakeInCatalog(
                              projectId: summary.projectId,
                              partId: take.partId,
                            );
                          },
                          child: const Text('Purge'),
                        ),
                      );
                    },
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }
}

@immutable
final class _CreateBlankProjectRequest {
  final String title;
  final SoundFontId soundFontId;
  final int tempoBpm;
  final int numerator;
  final int denominator;
  final int stavesCount;

  const _CreateBlankProjectRequest({
    required this.title,
    required this.soundFontId,
    required this.tempoBpm,
    required this.numerator,
    required this.denominator,
    required this.stavesCount,
  });
}

final class _CreateBlankProjectDialog extends StatefulWidget {
  final List<SoundFontCatalogEntry> soundFonts;

  const _CreateBlankProjectDialog({required this.soundFonts});

  @override
  State<_CreateBlankProjectDialog> createState() =>
      _CreateBlankProjectDialogState();
}

final class _CreateBlankProjectDialogState
    extends State<_CreateBlankProjectDialog> {
  late final TextEditingController _titleController;
  late final TextEditingController _tempoController;
  late int _numerator;
  late int _denominator;
  late int _stavesCount;
  SoundFontId? _selectedSfId;
  String? _validationError;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(
      text: MusePresentationConstants.defaultBlankProjectTitle,
    );
    _tempoController = TextEditingController(
      text: MusePresentationConstants.defaultNewProjectTempoBpm.toString(),
    );
    _numerator = MusePresentationConstants.defaultNewProjectTimeSigNum;
    _denominator = MusePresentationConstants.defaultNewProjectTimeSigDen;
    _stavesCount = MusePresentationConstants.defaultInitialPartStavesCount;
    _selectedSfId = widget.soundFonts.firstOrNull?.sfId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _tempoController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final denominators =
        TempoTimelineCalculator.validTimeSigDenominators.toList()..sort();
    return AlertDialog(
      title: const Text('New Blank Project'),
      content: SizedBox(
        width: MusePresentationConstants.dialogMaxWidthPx,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              TextField(
                key: const Key('new_project_title_field'),
                controller: _titleController,
                decoration: const InputDecoration(labelText: 'Project Title'),
              ),
              const SizedBox(
                height: MusePresentationConstants.standardControlGapPx,
              ),
              TextField(
                key: const Key('new_project_tempo_field'),
                controller: _tempoController,
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  labelText:
                      'Initial Tempo (${TelemetryConstants.bpmMinValid}..${TelemetryConstants.bpmMaxValid} BPM)',
                ),
              ),
              const SizedBox(
                height: MusePresentationConstants.standardControlGapPx,
              ),
              Row(
                children: [
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: const Key('new_project_ts_num'),
                      initialValue: _numerator,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: 'Beats / Bar',
                      ),
                      items: ProjectCatalogView._supportedNumerators
                          .map(
                            (n) => DropdownMenuItem<int>(
                              value: n,
                              child: Text('$n'),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _numerator = v);
                        }
                      },
                    ),
                  ),
                  const SizedBox(
                    width: MusePresentationConstants.standardControlGapPx,
                  ),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      key: const Key('new_project_ts_den'),
                      initialValue: _denominator,
                      isExpanded: true,
                      decoration: const InputDecoration(labelText: 'Beat Unit'),
                      items: denominators
                          .map(
                            (d) => DropdownMenuItem<int>(
                              value: d,
                              child: Text('$d'),
                            ),
                          )
                          .toList(growable: false),
                      onChanged: (v) {
                        if (v != null) {
                          setState(() => _denominator = v);
                        }
                      },
                    ),
                  ),
                ],
              ),
              const SizedBox(
                height: MusePresentationConstants.standardControlGapPx,
              ),
              DropdownButtonFormField<int>(
                key: const Key('new_project_staves_dropdown'),
                initialValue: _stavesCount,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Initial Part Staves',
                ),
                items: const [
                  DropdownMenuItem<int>(
                    value: MusePresentationConstants.singleStaffNumber,
                    child: Text(
                      '1 Staff (Melody / Single Instrument)',
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  DropdownMenuItem<int>(
                    value: MusePresentationConstants.grandStaffStavesCount,
                    child: Text(
                      '2 Staves (Grand Staff / Piano)',
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
              const SizedBox(
                height: MusePresentationConstants.standardControlGapPx,
              ),
              if (widget.soundFonts.isEmpty)
                const Text(
                  'No SoundFonts installed. Import a .sf2 in SoundFonts Library first.',
                  style: TextStyle(
                    color: MusePresentationConstants.sessionErrorBannerText,
                  ),
                )
              else
                DropdownButtonFormField<SoundFontId>(
                  key: const Key('new_project_soundfont_dropdown'),
                  initialValue: _selectedSfId,
                  isExpanded: true,
                  decoration: const InputDecoration(
                    labelText: 'Initial Part SoundFont',
                  ),
                  items: widget.soundFonts
                      .map(
                        (sf) => DropdownMenuItem<SoundFontId>(
                          value: sf.sfId,
                          child: Text(
                            sf.name,
                            maxLines: MusePresentationConstants.titleMaxLines,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      )
                      .toList(growable: false),
                  onChanged: (v) => setState(() => _selectedSfId = v),
                ),
              if (_validationError != null) ...[
                const SizedBox(
                  height: MusePresentationConstants.standardControlGapPx,
                ),
                Text(
                  _validationError!,
                  style: const TextStyle(
                    color: MusePresentationConstants.sessionErrorBannerText,
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          key: const Key('new_project_cancel_button'),
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const Key('new_project_confirm_button'),
          onPressed: _selectedSfId == null
              ? null
              : () {
                  final parsedTempo = int.tryParse(
                    _tempoController.text.trim(),
                  );
                  if (parsedTempo == null ||
                      parsedTempo < TelemetryConstants.bpmMinValid ||
                      parsedTempo > TelemetryConstants.bpmMaxValid) {
                    setState(() {
                      _validationError =
                          'Tempo BPM must be between ${TelemetryConstants.bpmMinValid} and ${TelemetryConstants.bpmMaxValid}.';
                    });
                    return;
                  }
                  final trimmedTitle = _titleController.text.trim();
                  if (trimmedTitle.isEmpty) {
                    setState(() {
                      _validationError = 'Project title must not be empty.';
                    });
                    return;
                  }
                  Navigator.of(context).pop(
                    _CreateBlankProjectRequest(
                      title: trimmedTitle,
                      soundFontId: _selectedSfId!,
                      tempoBpm: parsedTempo,
                      numerator: _numerator,
                      denominator: _denominator,
                      stavesCount: _stavesCount,
                    ),
                  );
                },
          child: const Text('Create & Open'),
        ),
      ],
    );
  }
}

final class _RenameProjectDialog extends StatefulWidget {
  final String initialTitle;

  const _RenameProjectDialog({required this.initialTitle});

  @override
  State<_RenameProjectDialog> createState() => _RenameProjectDialogState();
}

final class _RenameProjectDialogState extends State<_RenameProjectDialog> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.initialTitle);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Rename Project'),
      content: TextField(
        key: const Key('rename_project_field'),
        controller: _controller,
        decoration: const InputDecoration(labelText: 'New Title'),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        ElevatedButton(
          key: const Key('rename_project_confirm_button'),
          onPressed: () {
            final nextTitle = _controller.text.trim();
            Navigator.of(context).pop(nextTitle);
          },
          child: const Text('Save'),
        ),
      ],
    );
  }
}
