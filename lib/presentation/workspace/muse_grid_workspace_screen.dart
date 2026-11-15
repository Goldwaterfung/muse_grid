/// Layer 5 adaptive top-level MuseGrid Workspace Screen switching between
/// Project Catalog and the synchronized Staff Notation + Piano Roll + Mixer DAW.
library;

import 'dart:async';

import 'package:material_ui/material_ui.dart';

import '../../domain/notation/dual_model_score_service.dart';
import '../controllers/audio_session_contract.dart';
import '../controllers/project_catalog_controller.dart';
import '../controllers/transport_and_telemetry_controller.dart';
import '../controllers/workspace_shell_controller.dart';
import '../notation/staff_notation_panel.dart';
import '../notation/staff_notation_view_controller.dart';
import '../piano_roll/piano_roll_panel.dart';
import '../piano_roll/piano_roll_viewport_controller.dart';
import '../theme/muse_presentation_constants.dart';
import 'part_mixer_sidebar.dart';
import 'project_catalog_view.dart';
import 'transport_toolbar.dart';

enum _CompactWorkspaceTab { notation, pianoRoll, mixer, catalog }

/// Adaptive shell screen binding L5 controllers and audio-session banners.
final class MuseGridWorkspaceScreen extends StatefulWidget {
  final ProjectCatalogController catalogController;
  final WorkspaceShellController workspaceController;
  final TransportAndTelemetryController transportController;
  final StaffNotationViewController staffNotationController;
  final PianoRollViewportController pianoRollController;
  final IAudioSessionController audioSessionController;
  final VoidCallback? onNotationPlayheadPaintForTest;
  final VoidCallback? onPianoRollGridPaintForTest;
  final VoidCallback? onPianoRollPlayheadPaintForTest;

  const MuseGridWorkspaceScreen({
    super.key,
    required this.catalogController,
    required this.workspaceController,
    required this.transportController,
    required this.staffNotationController,
    required this.pianoRollController,
    required this.audioSessionController,
    this.onNotationPlayheadPaintForTest,
    this.onPianoRollGridPaintForTest,
    this.onPianoRollPlayheadPaintForTest,
  });

  @override
  State<MuseGridWorkspaceScreen> createState() =>
      _MuseGridWorkspaceScreenState();
}

final class _MuseGridWorkspaceScreenState extends State<MuseGridWorkspaceScreen> {
  double _notationSplitRatio = MusePresentationConstants.splitPaneDefaultRatio;
  _CompactWorkspaceTab _compactTab = _CompactWorkspaceTab.notation;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            ValueListenableBuilder<AudioSessionStatus>(
              valueListenable: widget.audioSessionController.audioSessionStatus,
              builder: (context, status, _) => _buildAudioSessionBanner(status),
            ),
            Expanded(
              child: AnimatedBuilder(
                animation: widget.workspaceController,
                builder: (context, _) {
                  final workspace = widget.workspaceController.workspace;
                  if (workspace == null) {
                    return ProjectCatalogView(
                      key: const Key('project_catalog_view'),
                      catalogController: widget.catalogController,
                      workspaceController: widget.workspaceController,
                      audioSessionController: widget.audioSessionController,
                    );
                  }
                  return LayoutBuilder(
                    builder: (context, constraints) {
                      if (constraints.maxWidth <=
                          MusePresentationConstants.compactLayoutMaxWidthPx) {
                        return _buildCompactWorkspace(workspace);
                      }
                      return _buildDesktopWorkspace(workspace);
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAudioSessionBanner(AudioSessionStatus status) {
    switch (status.phase) {
      case AudioSessionPhase.requiresWebUserGesture:
        return Container(
          key: const Key('web_audio_gesture_banner'),
          padding: const EdgeInsets.all(
            MusePresentationConstants.statusBannerPaddingPx,
          ),
          decoration: const BoxDecoration(
            color: MusePresentationConstants.webGestureBannerBackground,
            border: Border(
              bottom: BorderSide(
                color: MusePresentationConstants.webGestureBannerBorder,
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.volume_up,
                color: MusePresentationConstants.webGestureBannerText,
              ),
              const SizedBox(
                width: MusePresentationConstants.standardControlGapPx,
              ),
              const Expanded(
                child: Text(
                  'Browser audio requires an explicit user gesture to start the AudioWorklet engine.',
                  style: TextStyle(
                    color: MusePresentationConstants.webGestureBannerText,
                  ),
                ),
              ),
              ElevatedButton(
                key: const Key('enable_web_audio_button'),
                onPressed: () => unawaited(
                  widget.workspaceController.ensureAudioInitializedAndAttach(),
                ),
                child: const Text('Click to Enable Web Audio Engine'),
              ),
            ],
          ),
        );
      case AudioSessionPhase.failed:
        final error = status.error;
        return Container(
          key: const Key('audio_session_failed_banner'),
          padding: const EdgeInsets.all(
            MusePresentationConstants.statusBannerPaddingPx,
          ),
          decoration: const BoxDecoration(
            color: MusePresentationConstants.sessionErrorBannerBackground,
            border: Border(
              bottom: BorderSide(
                color: MusePresentationConstants.sessionErrorBannerBorder,
              ),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.warning_amber,
                color: MusePresentationConstants.sessionErrorBannerText,
              ),
              const SizedBox(
                width: MusePresentationConstants.standardControlGapPx,
              ),
              Expanded(
                child: Text(
                  error != null
                      ? '${error.code.name}: ${error.message}'
                      : 'Audio hardware session failed.',
                  style: const TextStyle(
                    color: MusePresentationConstants.sessionErrorBannerText,
                  ),
                ),
              ),
              OutlinedButton(
                key: const Key('retry_audio_init_button'),
                onPressed: () => unawaited(
                  widget.workspaceController.ensureAudioInitializedAndAttach(),
                ),
                child: const Text('Retry Audio'),
              ),
            ],
          ),
        );
      case AudioSessionPhase.initializing:
        return Container(
          key: const Key('audio_session_initializing_banner'),
          padding: const EdgeInsets.all(
            MusePresentationConstants.shellCompactGapPx * 2,
          ),
          child: const Row(
            children: [
              SizedBox(
                width: MusePresentationConstants.statusIconSizePx,
                height: MusePresentationConstants.statusIconSizePx,
                child: CircularProgressIndicator(),
              ),
              SizedBox(width: MusePresentationConstants.standardControlGapPx),
              Text('Initializing audio hardware session...'),
            ],
          ),
        );
      case AudioSessionPhase.ready:
        return const SizedBox.shrink();
    }
  }

  Widget _buildDesktopWorkspace(ScoreWorkspaceState workspace) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TransportToolbar(
          catalogController: widget.catalogController,
          workspaceController: widget.workspaceController,
          transportController: widget.transportController,
          audioSessionController: widget.audioSessionController,
          workspace: workspace,
        ),
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              SizedBox(
                width: MusePresentationConstants.mixerSidebarWidthPx,
                child: PartMixerSidebar(
                  catalogController: widget.catalogController,
                  workspaceController: widget.workspaceController,
                  transportController: widget.transportController,
                  workspace: workspace,
                ),
              ),
              Expanded(
                child: LayoutBuilder(
                  builder: (context, splitConstraints) {
                    final availableHeight = splitConstraints.maxHeight;
                    final dividerHeight =
                        MusePresentationConstants.splitDividerHeightPx;
                    final contentHeight =
                        (availableHeight - dividerHeight).clamp(
                          MusePresentationConstants.zeroAmplitude,
                          double.infinity,
                        );
                    final notationHeight =
                        contentHeight * _notationSplitRatio;
                    final pianoRollHeight = contentHeight - notationHeight;

                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        SizedBox(
                          height: notationHeight,
                          child: StaffNotationPanel(
                            controller: widget.staffNotationController,
                            workspaceController: widget.workspaceController,
                            transportController: widget.transportController,
                            onPlayheadPaintForTest:
                                widget.onNotationPlayheadPaintForTest,
                          ),
                        ),
                        MouseRegion(
                          cursor: SystemMouseCursors.resizeRow,
                          child: GestureDetector(
                            behavior: HitTestBehavior.opaque,
                            onVerticalDragUpdate: (details) {
                              if (contentHeight <=
                                  MusePresentationConstants.zeroAmplitude) {
                                return;
                              }
                              setState(() {
                                _notationSplitRatio =
                                    ((notationHeight + details.delta.dy) /
                                            contentHeight)
                                        .clamp(
                                          MusePresentationConstants
                                              .splitPaneMinRatio,
                                          MusePresentationConstants
                                              .splitPaneMaxRatio,
                                        );
                              });
                            },
                            child: Container(
                              height: dividerHeight,
                              color: Theme.of(context).dividerColor,
                            ),
                          ),
                        ),
                        SizedBox(
                          height: pianoRollHeight,
                          child: PianoRollPanel(
                            controller: widget.pianoRollController,
                            workspaceController: widget.workspaceController,
                            transportController: widget.transportController,
                            onGridPaintForTest:
                                widget.onPianoRollGridPaintForTest,
                            onPlayheadPaintForTest:
                                widget.onPianoRollPlayheadPaintForTest,
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
      ],
    );
  }

  Widget _buildCompactWorkspace(ScoreWorkspaceState workspace) {
    final Widget activeTabWidget = switch (_compactTab) {
      _CompactWorkspaceTab.notation => StaffNotationPanel(
        controller: widget.staffNotationController,
        workspaceController: widget.workspaceController,
        transportController: widget.transportController,
        onPlayheadPaintForTest: widget.onNotationPlayheadPaintForTest,
      ),
      _CompactWorkspaceTab.pianoRoll => PianoRollPanel(
        controller: widget.pianoRollController,
        workspaceController: widget.workspaceController,
        transportController: widget.transportController,
        onGridPaintForTest: widget.onPianoRollGridPaintForTest,
        onPlayheadPaintForTest: widget.onPianoRollPlayheadPaintForTest,
      ),
      _CompactWorkspaceTab.mixer => PartMixerSidebar(
        catalogController: widget.catalogController,
        workspaceController: widget.workspaceController,
        transportController: widget.transportController,
        workspace: workspace,
      ),
      _CompactWorkspaceTab.catalog => ProjectCatalogView(
        catalogController: widget.catalogController,
        workspaceController: widget.workspaceController,
        audioSessionController: widget.audioSessionController,
      ),
    };

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        TransportToolbar(
          catalogController: widget.catalogController,
          workspaceController: widget.workspaceController,
          transportController: widget.transportController,
          audioSessionController: widget.audioSessionController,
          workspace: workspace,
        ),
        Expanded(child: activeTabWidget),
        SizedBox(
          height: MusePresentationConstants.compactTabBarHeightPx,
          child: NavigationBar(
            key: const Key('compact_workspace_navigation'),
            selectedIndex: _compactTab.index,
            onDestinationSelected: (index) => setState(() {
              _compactTab = _CompactWorkspaceTab.values[index];
            }),
            destinations: const [
              NavigationDestination(
                icon: Icon(Icons.music_note),
                label: 'Notation',
              ),
              NavigationDestination(
                icon: Icon(Icons.piano),
                label: 'Piano Roll',
              ),
              NavigationDestination(
                icon: Icon(Icons.tune),
                label: 'Mixer',
              ),
              NavigationDestination(
                icon: Icon(Icons.folder),
                label: 'Catalog',
              ),
            ],
          ),
        ),
      ],
    );
  }
}
