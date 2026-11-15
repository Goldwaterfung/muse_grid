/// Native microphone runtime permission seam for Middle Bridge audio setup.
library;

import 'dart:io';

import 'package:flutter/services.dart';

import '../contracts/engine_constants.dart';
import '../contracts/result.dart';

/// Seam verifying native OS microphone capture permission before initializing
/// Layer 1 duplex HAL or starting audio capture.
abstract interface class INativeAudioPermissionChecker {
  /// Ensures microphone capture permission is granted or fails closed with
  /// [MuseErrorCode.microphonePermissionDenied].
  Future<Result<void>> ensureMicrophonePermission();
}

/// Platform implementation delegating Android runtime `RECORD_AUDIO` checks
/// to `MainActivity.kt` via `MethodChannel` while bypassing interactive prompts
/// in headless CI mode (`MUSE_HEADLESS_AUDIO=1`) and desktop/iOS hosts where
/// CoreAudio/AVAudioSession handle entitlement prompts directly.
final class PlatformAudioPermissionChecker
    implements INativeAudioPermissionChecker {
  /// MethodChannel shared with Android `MainActivity.kt`.
  static const String channelName = 'musegrid/audio_permissions';

  /// Method name invoked on [channelName] to ensure `RECORD_AUDIO`.
  static const String ensurePermissionMethod = 'ensureRecordAudioPermission';

  /// Environment variable value enabling headless CI audio HAL.
  static const String headlessEnabledValue = '1';

  final MethodChannel _channel;
  final bool _isAndroid;
  final Map<String, String> _environment;

  /// Creates a permission checker, optionally overriding platform detection,
  /// environment variables, or the [MethodChannel] for unit tests.
  PlatformAudioPermissionChecker({
    MethodChannel? channel,
    bool? isAndroidOverride,
    Map<String, String>? environmentOverride,
  }) : _channel = channel ?? const MethodChannel(channelName),
       _isAndroid = isAndroidOverride ?? Platform.isAndroid,
       _environment = environmentOverride ?? Platform.environment;

  @override
  Future<Result<void>> ensureMicrophonePermission() async {
    if (_environment[MuseConstants.headlessAudioEnvVar] ==
            headlessEnabledValue ||
        !_isAndroid) {
      return const Ok(null);
    }

    try {
      final granted = await _channel.invokeMethod<bool>(ensurePermissionMethod);
      if (granted == true) {
        return const Ok(null);
      }
      return const Err(
        MuseError(
          MuseErrorCode.microphonePermissionDenied,
          'Android RECORD_AUDIO microphone permission was denied.',
        ),
      );
    } on PlatformException catch (error) {
      return Err(
        MuseError(
          MuseErrorCode.microphonePermissionDenied,
          'Android RECORD_AUDIO permission request failed.',
          cause: error,
        ),
      );
    } on MissingPluginException catch (error) {
      // Fail closed if the native permission channel is unregistered on Android.
      return Err(
        MuseError(
          MuseErrorCode.microphonePermissionDenied,
          'Audio permission platform channel is unavailable on Android.',
          cause: error,
        ),
      );
    }
  }
}
