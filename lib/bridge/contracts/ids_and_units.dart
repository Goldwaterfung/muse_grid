/// Zero-cost Dart 3 extension types for strongly typed entity IDs and units.
library;

extension type const ProjectId(String value) {}

extension type const PartId(String value) {}

extension type const NoteId(String value) {}

extension type const SpannerId(String value) {}

extension type const TempoEventId(String value) {}

extension type const TimeSigEventId(String value) {}

extension type const KeySigEventId(String value) {}

extension type const ClefEventId(String value) {}

extension type const TakeId(String value) {}

extension type const SoundFontId(String value) {}

extension type const CalibrationProfileId(String value) {}

extension type const Sha256Digest(String value) {}

/// Canonical 960 PPQN musical timeline tick.
extension type const Tick(int value) {}

/// 64-bit hardware audio sample frame position.
extension type const SampleFrame(int value) {}

/// Monotonic playback/scheduler invalidation epoch.
extension type const EpochId(int value) {}

/// Ephemeral runtime FluidSynth `sfont_id` (`int32_t`).
extension type const SoundFontHandle(int value) {}
