/// Fail-closed conditional-import stub for unsupported Dart targets lacking both
/// `dart.library.io` and `dart.library.js_interop`.
library;

import '../presentation/theme/muse_presentation_constants.dart';
import 'platform_wiring_types.dart';

/// Rejects unsupported compilation targets loudly instead of providing fake IO.
MuseGridPlatformWiring createPlatformWiring() {
  throw UnsupportedError(BootstrapConstants.unsupportedPlatformMessage);
}
