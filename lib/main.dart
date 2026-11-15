/// Application entrypoint mounting [MuseGridRootApp] over fail-closed
/// [MuseGridAppBootstrap] lifecycle and adaptive [MuseGridWorkspaceScreen].
library;

import 'dart:async';
import 'dart:ui' show AppExitResponse;

import 'package:material_ui/material_ui.dart';

import 'app/muse_grid_app_bootstrap.dart';
import 'bridge/contracts/result.dart';
import 'presentation/theme/muse_presentation_constants.dart';
import 'presentation/workspace/muse_grid_workspace_screen.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const MuseGridRootApp());
}

/// Top-level application widget owning a single cached bootstrap initialization
/// future and reverse-order disposal across app exit and widget teardown.
final class MuseGridRootApp extends StatefulWidget {
  final MuseGridAppBootstrap? bootstrapOverride;
  final VoidCallback? onNotationPlayheadPaintForTest;
  final VoidCallback? onPianoRollGridPaintForTest;
  final VoidCallback? onPianoRollPlayheadPaintForTest;

  const MuseGridRootApp({
    super.key,
    this.bootstrapOverride,
    this.onNotationPlayheadPaintForTest,
    this.onPianoRollGridPaintForTest,
    this.onPianoRollPlayheadPaintForTest,
  });

  @override
  State<MuseGridRootApp> createState() => _MuseGridRootAppState();
}

final class _MuseGridRootAppState extends State<MuseGridRootApp> {
  late final MuseGridAppBootstrap _bootstrap;
  late final AppLifecycleListener _lifecycleListener;
  late Future<Result<MuseGridControllerBundle>> _initializeFuture;

  @override
  void initState() {
    super.initState();
    _bootstrap = widget.bootstrapOverride ?? MuseGridAppBootstrap();
    _initializeFuture = _bootstrap.initialize();
    _lifecycleListener = AppLifecycleListener(
      onExitRequested: () async {
        await _bootstrap.dispose();
        return AppExitResponse.exit;
      },
    );
  }

  @override
  void dispose() {
    _lifecycleListener.dispose();
    unawaited(_bootstrap.dispose());
    super.dispose();
  }

  void _retryStartup() {
    setState(() {
      _initializeFuture = _bootstrap.initialize();
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: BootstrapConstants.appTitle,
      home: FutureBuilder<Result<MuseGridControllerBundle>>(
        future: _initializeFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Scaffold(
              key: Key('bootstrap_loading_screen'),
              body: Center(
                child: Padding(
                  padding: EdgeInsets.all(
                    BootstrapConstants.startupContentPaddingPx,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      CircularProgressIndicator(),
                      SizedBox(
                        height: BootstrapConstants.startupElementGapPx,
                      ),
                      Text(
                        BootstrapConstants.initializingStatusMessage,
                        textAlign: TextAlign.center,
                      ),
                    ],
                  ),
                ),
              ),
            );
          }

          if (snapshot.hasError) {
            return _StartupFatalErrorScreen(
              errorCode: MuseErrorCode.audioDeviceInitFailed.name,
              errorMessage: '${snapshot.error}',
              onRetry: _retryStartup,
            );
          }

          final result = snapshot.data;
          if (result == null) {
            return _StartupFatalErrorScreen(
              errorCode: MuseErrorCode.sqliteConstraintViolation.name,
              errorMessage: 'Bootstrap completed without a startup result.',
              onRetry: _retryStartup,
            );
          }

          switch (result) {
            case Err<MuseGridControllerBundle>(:final error):
              return _StartupFatalErrorScreen(
                errorCode: error.code.name,
                errorMessage: error.message,
                onRetry: _retryStartup,
              );
            case Ok<MuseGridControllerBundle>(:final value):
              return MuseGridWorkspaceScreen(
                catalogController: value.projectCatalogController,
                workspaceController: value.workspaceShellController,
                transportController: value.transportAndTelemetryController,
                staffNotationController: value.staffNotationViewController,
                pianoRollController: value.pianoRollViewportController,
                audioSessionController: value.audioSessionController,
                onNotationPlayheadPaintForTest:
                    widget.onNotationPlayheadPaintForTest,
                onPianoRollGridPaintForTest: widget.onPianoRollGridPaintForTest,
                onPianoRollPlayheadPaintForTest:
                    widget.onPianoRollPlayheadPaintForTest,
              );
          }
        },
      ),
    );
  }
}

final class _StartupFatalErrorScreen extends StatelessWidget {
  final String errorCode;
  final String errorMessage;
  final VoidCallback onRetry;

  const _StartupFatalErrorScreen({
    required this.errorCode,
    required this.errorMessage,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      key: const Key('bootstrap_fatal_error_screen'),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(
            maxWidth: BootstrapConstants.startupCardMaxWidthPx,
          ),
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(
                BootstrapConstants.startupContentPaddingPx,
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.error_outline,
                        color: MusePresentationConstants.sessionErrorBannerText,
                      ),
                      SizedBox(
                        width: MusePresentationConstants.standardControlGapPx,
                      ),
                      Text('MuseGrid Startup Failed'),
                    ],
                  ),
                  const SizedBox(
                    height: BootstrapConstants.startupElementGapPx,
                  ),
                  Text(
                    'Error Code: $errorCode',
                    style: const TextStyle(
                      color: MusePresentationConstants.sessionErrorBannerText,
                    ),
                  ),
                  const SizedBox(
                    height: MusePresentationConstants.standardControlGapPx,
                  ),
                  Text(errorMessage),
                  const SizedBox(
                    height: BootstrapConstants.startupElementGapPx,
                  ),
                  ElevatedButton(
                    key: const Key('bootstrap_retry_button'),
                    onPressed: onRetry,
                    child: const Text('Retry Startup'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
