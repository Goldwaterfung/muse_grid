/// Centralized presentation layout, timing, engraving, Piano Roll, and telemetry
/// constants for Layer 5 (`lib/presentation/`) so zero magic values sit inline.
library;

import 'package:crisp_notation/crisp_notation.dart';
import 'package:flutter/widgets.dart';

import '../../bridge/contracts/engine_constants.dart';

/// Centralized catalog, storage-maintenance, mixer, and calibration defaults.
abstract final class MusePresentationConstants {
  /// Pagination slice size passed as `limit` to `IProjectRepository.listActiveProjects`.
  static const int catalogPageSize = 25;

  /// Soft-delete retention window in days before automatic startup GC hard-deletes.
  static const int softDeleteRetentionDays = 7;

  /// Soft-delete retention window in milliseconds (`604_800_000` ms).
  static const int softDeleteRetentionMs =
      softDeleteRetentionDays * Duration.millisecondsPerDay;

  static const int defaultNewProjectTempoBpm = 120;

  /// Microseconds per minute (`60_000_000`) for BPM <-> `usPerQuarter` conversions.
  static const int microsecondsPerMinute = 60 * Duration.microsecondsPerSecond;

  static const int defaultNewProjectUsPerQuarter =
      microsecondsPerMinute ~/ defaultNewProjectTempoBpm;

  static const int defaultNewProjectTimeSigNum = 4;
  static const int defaultNewProjectTimeSigDen = 4;
  static const int defaultPickupTicks = 0;
  static const int defaultGridSnapTicks = MuseConstants.sixteenthNoteTicks;
  static const int defaultInitialPartStavesCount = 1;
  static const int singleStaffNumber = 1;
  static const int grandStaffLowerNumber = 2;
  static const int minVoiceNumber = 1;
  static const int maxVoiceNumber = 4;
  static const int initialTick = 0;
  static const int initialPartSortOrder = 0;
  static const int firstPartSequenceNumber = 1;
  static const int defaultClefOctaveChange = 0;
  static const int countInDisabledMeasures = 0;

  static const String defaultBlankProjectTitle = 'Untitled Score';
  static const String defaultInitialPartName = 'Piano';
  static const String musicXmlPartIdPrefix = 'P';
  static const String musicXmlPrimaryExtension = 'musicxml';
  static const String compressedMxlExtension = 'mxl';
  static const List<String> importMusicXmlExtensions = <String>[
    'musicxml',
    'xml',
    'mxl',
  ];
  static const List<String> importSoundFontExtensions = <String>['sf2'];
  static const String musicXmlMimeType =
      'application/vnd.recordare.musicxml+xml';
  static const String mxlMimeType = 'application/vnd.recordare.musicxml';
  static const String wavExportFileSuffix = '.wav';
  static const String musicXmlExportFileSuffix = '.musicxml';
  static const String mxlExportFileSuffix = '.mxl';

  // Responsive Breakpoints & Panel Geometry
  static const double compactLayoutMaxWidthPx = 840.0;
  static const double mixerSidebarWidthPx = 296.0;
  static const double transportToolbarMinHeightPx = 64.0;
  static const double statusBannerPaddingPx = 12.0;
  static const double standardControlGapPx = 8.0;
  static const double mixerGainMinDb = -60.0;
  static const double mixerGainMaxDb = 6.0;
  static const double mixerPanMin = -1.0;
  static const double mixerPanMax = 1.0;

  static const int millisecondsPerSecond = 1000;

  /// Maximum round-trip hardware offset magnitude (`±1000 ms`), converted
  /// dynamically to frames using `hw.sampleRate`.
  static const int calibrationMaxOffsetMs = 1000;

  /// Minimum calibration stepper increment (`1 ms`), scaled by `hw.sampleRate`.
  static const int calibrationStepMs = 1;

  /// Canonical snap & note-value subdivision list composed exclusively from
  /// `MuseConstants` tick fields.
  static const List<int> supportedSubdivisionTicks = <int>[
    MuseConstants.wholeNoteTicks,
    MuseConstants.halfNoteTicks,
    MuseConstants.quarterNoteTicks,
    MuseConstants.eighthNoteTicks,
    MuseConstants.sixteenthNoteTicks,
    MuseConstants.thirtySecondNoteTicks,
    MuseConstants.sixtyFourthNoteTicks,
    MuseConstants.dottedHalfNoteTicks,
    MuseConstants.dottedQuarterNoteTicks,
    MuseConstants.dottedEighthNoteTicks,
    MuseConstants.dottedSixteenthNoteTicks,
    MuseConstants.dottedThirtySecondNoteTicks,
    MuseConstants.tripletHalfNoteTicks,
    MuseConstants.tripletQuarterNoteTicks,
    MuseConstants.tripletEighthNoteTicks,
    MuseConstants.tripletSixteenthNoteTicks,
    MuseConstants.tripletThirtySecondNoteTicks,
  ];

  // SMuFL / crisp_notation Theme & Asset Binding
  static const MusicFont defaultMusicFont = MusicFont.bravura;
  static const CrispNotationTheme defaultNotationTheme =
      CrispNotationTheme.standard;

  // Workspace Shell, Catalog, Mixer & Calibration Constants (Task 6.3)
  static const int defaultPresetBankNum = 0;
  static const int defaultPresetProgramNum = 0;
  static const int grandStaffStavesCount = 2;
  static const int minimumProjectPartsCount = 1;
  static const int sha256PrefixDisplayLength = 8;
  static const int minCalibrationStepFrames = 1;
  static const int defaultLoopSpanBars = 4;

  /// Exclusive loop `endTick` sits 1 tick past the last included tick in the span.
  static const int inclusiveLoopEndTickOffset = 1;
  static const int beatDisplayIndexOffset = 1;
  static const int mixerGainDivisions = 66;
  static const int mixerPanDivisions = 40;
  static const int monitorGainDivisions = 100;
  static const int titleMaxLines = 1;
  static const int errorMessageMaxLines = 3;

  static const double shellCardPaddingPx = 12.0;
  static const double shellSectionGapPx = 12.0;
  static const double shellCompactGapPx = 4.0;
  static const double dialogMaxWidthPx = 520.0;
  static const double dialogListMaxHeightPx = 320.0;
  static const double compactTabBarHeightPx = 56.0;
  static const double meterBarWidthPx = 72.0;
  static const double waveformStripWidthPx = 96.0;
  static const double waveformStripHeightPx = 28.0;
  static const double waveformBarStrokePx = 2.0;
  static const double mixerSliderWidthPx = 140.0;
  static const double splitPaneMinRatio = 0.25;
  static const double splitPaneMaxRatio = 0.75;
  static const double splitPaneDefaultRatio = 0.45;
  static const double splitDividerHeightPx = 6.0;
  static const double statusBadgeBorderWidthPx = 1.0;
  static const double statusIconSizePx = 18.0;
  static const double zeroAmplitude = 0.0;
  static const double unitFraction = 1.0;
  static const double clockFieldWidthPx = 148.0;
  static const double pickupFieldWidthPx = 76.0;
  static const double decimalPrecisionOneDigit = 1.0;

  static const Color webGestureBannerBackground = Color(0xFFFFFBEB);
  static const Color webGestureBannerBorder = Color(0xFFD97706);
  static const Color webGestureBannerText = Color(0xFF92400E);
  static const Color sessionErrorBannerBackground = Color(0xFFFEF2F2);
  static const Color sessionErrorBannerBorder = Color(0xFFDC2626);
  static const Color sessionErrorBannerText = Color(0xFF991B1B);
  static const Color readyBadgeBackground = Color(0xFFECFDF5);
  static const Color readyBadgeText = Color(0xFF065F46);
  static const Color meterNormalColor = Color(0xFF22C55E);
  static const Color meterWarnColor = Color(0xFFF59E0B);
  static const Color meterClipColor = Color(0xFFEF4444);
  static const Color meterTrackColor = Color(0xFF1E293B);
  static const Color waveformActiveColor = Color(0xFF38BDF8);
  static const Color partSelectedBackground = Color(0xFFE0F2FE);
  static const Color recordingActiveColor = Color(0xFFDC2626);
  static const Color loopActiveColor = Color(0xFF16A34A);

  /// Formats a canonical tick subdivision from `MuseConstants` into a UI label.
  static String formatSubdivisionLabel(int ticks) => switch (ticks) {
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
    _ => '$ticks ticks',
  };
}

/// Centralized engraving layout and score editor constants for Staff Notation.
abstract final class NotationViewConstants {
  static const double baseStaffSpacePx = 7.0;
  static const double minZoomScale = 0.6;
  static const double maxZoomScale = 2.0;
  static const double defaultZoomScale = 1.0;
  static const double zoomStepScale = 0.15;

  /// Matches `StaffSystemView` default inter-staff gap in staff spaces.
  static const double staffGapSpaces = 4.0;
  static const double notationViewportPaddingPx = 16.0;
  static const int minKeySignatureFifths = -7;
  static const int maxKeySignatureFifths = 7;
  static const int minClefLine = 1;
  static const int maxClefLine = 5;
  static const int minClefOctaveChange = -2;
  static const int maxClefOctaveChange = 2;
  static const int minSpannerLevel = 1;
  static const int maxSpannerLevel = 6;
  static const int diatonicStepsPerOctave = 7;
  static const int semitonesPerOctave = 12;
  static const int middleCMidiPitch = 60;
  static const int defaultNoteEntryVelocity = 96;
  static const int auditionNoteDurationMs = 240;
  static const int initialMapTick = 0;
  static const int chromaticSemitoneUp = 1;
  static const int chromaticSemitoneDown = -1;
  static const int chromaticOctaveUp = 12;
  static const int chromaticOctaveDown = -12;
  static const double playheadLineStrokePx = 1.75;
  static const double caretLineStrokePx = 2.0;
  static const double inspectorPanelWidthPx = 288.0;
  static const double errorBannerPaddingPx = 16.0;
  static const double toolbarHeightPx = 48.0;
  static const double defaultSpacingStretch = 1.0;
  static const double standardStaffHeightSpaces = 4.0;
  static const double standardStaffHalfHeightSpaces = 2.0;
  static const double inspectorDividerHeightPx = 1.0;
  static const double dialogFieldWidthPx = 120.0;

  /// Warm ivory engraving paper surface color.
  static const Color notationSurfaceColor = Color(0xFFFAF8F2);
  static const Color notationBorderColor = Color(0xFFD6D0C4);
  static const Color playheadColor = Color(0xFFDC2626);
  static const Color caretColor = Color(0xFF2563EB);
  static const Color errorBannerColor = Color(0xFFFEF2F2);
  static const Color errorBannerBorderColor = Color(0xFFDC2626);
  static const Color errorBannerTextColor = Color(0xFF991B1B);
}

/// Centralized Piano Roll geometry, zoom/LOD thresholds, and color tokens.
abstract final class PianoRollLayoutConstants {
  static const int minPitchMidi = MuseConstants.minMidiPitch;
  static const int maxPitchMidi = MuseConstants.maxMidiPitch;
  static const int totalPitchRows = maxPitchMidi - minPitchMidi + 1;
  static const int initialScrollCenterPitchMidi = 60;
  static const double minRowHeightPx = 10.0;
  static const double defaultRowHeightPx = 18.0;
  static const double maxRowHeightPx = 32.0;
  static const double keyGutterWidthPx = 56.0;
  static const double rulerHeightPx = 32.0;
  static const double takeStripHeightPx = 44.0;
  static const double velocityLaneHeightPx = 72.0;
  static const double horizontalPaddingTicks =
      4.0 * MuseConstants.wholeNoteTicks;
  static const int minimumCanvasBars = 8;

  // Horizontal Zoom & Dynamic LOD Thresholds
  static const double minPixelsPerTick = 0.02;
  static const double defaultPixelsPerTick = 0.125;
  static const double maxPixelsPerTick = 0.80;
  static const double zoomMultiplierStep = 1.25;

  /// Subdivision lines closer than `14.0 px` step up cleanly to the next coarser
  /// canonical subdivision in `MuseConstants`.
  static const double minReadableGridLineSpacingPx = 14.0;
  static const double noteResizeHandleWidthPx = 8.0;
  static const double minimumEditableDurationScale = 1.0;
  static const double playheadLineStrokePx = 1.75;
  static const double barlineStrokePx = 1.4;
  static const double beatLineStrokePx = 1.0;
  static const double subdivisionLineStrokePx = 0.6;

  static const List<int> straightLodLadderTicks = <int>[
    MuseConstants.sixtyFourthNoteTicks,
    MuseConstants.thirtySecondNoteTicks,
    MuseConstants.sixteenthNoteTicks,
    MuseConstants.eighthNoteTicks,
    MuseConstants.quarterNoteTicks,
    MuseConstants.halfNoteTicks,
    MuseConstants.wholeNoteTicks,
  ];

  static const List<int> dottedLodLadderTicks = <int>[
    MuseConstants.dottedThirtySecondNoteTicks,
    MuseConstants.dottedSixteenthNoteTicks,
    MuseConstants.dottedEighthNoteTicks,
    MuseConstants.dottedQuarterNoteTicks,
    MuseConstants.dottedHalfNoteTicks,
    MuseConstants.wholeNoteTicks,
  ];

  static const List<int> tripletLodLadderTicks = <int>[
    MuseConstants.tripletThirtySecondNoteTicks,
    MuseConstants.tripletSixteenthNoteTicks,
    MuseConstants.tripletEighthNoteTicks,
    MuseConstants.tripletQuarterNoteTicks,
    MuseConstants.tripletHalfNoteTicks,
    MuseConstants.wholeNoteTicks,
  ];

  static const Set<int> dottedSubdivisionTicks = <int>{
    MuseConstants.dottedThirtySecondNoteTicks,
    MuseConstants.dottedSixteenthNoteTicks,
    MuseConstants.dottedEighthNoteTicks,
    MuseConstants.dottedQuarterNoteTicks,
    MuseConstants.dottedHalfNoteTicks,
  };

  static const Set<int> tripletSubdivisionTicks = <int>{
    MuseConstants.tripletThirtySecondNoteTicks,
    MuseConstants.tripletSixteenthNoteTicks,
    MuseConstants.tripletEighthNoteTicks,
    MuseConstants.tripletQuarterNoteTicks,
    MuseConstants.tripletHalfNoteTicks,
  };

  /// 12-TET chromatic black-key pitch classes (`C#, D#, F#, G#, A#`).
  static const Set<int> blackKeyPitchClasses = <int>{1, 3, 6, 8, 10};

  // Color & Alpha Tokens
  static const double velocityMinOpacity = 0.35;
  static const double velocityOpacitySpan = 0.65;
  static const double ghostPreviewAlpha = 0.45;
  static const double loopRegionFillAlpha = 0.14;
  static const Color lightRowBackground = Color(0xFF1E222A);
  static const Color blackKeyRowBackground = Color(0xFF171A21);
  static const Color octaveC4DividerColor = Color(0xFF475569);
  static const Color barlineColor = Color(0xFF64748B);
  static const Color beatLineColor = Color(0xFF334155);
  static const Color subdivisionLineColor = Color(0xFF27303F);
  static const Color noteFillColor = Color(0xFF38BDF8);
  static const Color noteSelectedStrokeColor = Color(0xFFFACC15);
  static const Color playheadColor = Color(0xFFEF4444);
  static const Color loopRegionBaseColor = Color(0xFF22C55E);
  static const Color takeStripFillColor = Color(0xFF0EA5E9);

  // Extended Piano Roll Geometry & Colors
  static const double minNoteRectWidthPx = 4.0;
  static const double selectedNoteStrokeWidthPx = 2.0;
  static const double noteBorderRadiusPx = 3.0;
  static const double marqueeStrokeWidthPx = 1.25;
  static const double marqueeFillAlpha = 0.16;
  static const double takeStripFillAlpha = 0.25;
  static const double takeStripBorderWidthPx = 1.2;
  static const double velocityStemStrokePx = 4.0;
  static const double velocityBarMinHeightPx = 4.0;
  static const double loopBracketHeightPx = 8.0;
  static const double rulerLabelFontSizePx = 11.0;
  static const double keyLabelFontSizePx = 10.0;
  static const double keyLabelPaddingPx = 4.0;
  static const Color canvasBackgroundColor = Color(0xFF14171F);
  static const Color whiteKeyBackgroundColor = Color(0xFFF8FAFC);
  static const Color blackKeyBackgroundColor = Color(0xFF1E293B);
  static const Color keyDividerColor = Color(0xFF94A3B8);
  static const Color whiteKeyLabelColor = Color(0xFF0F172A);
  static const Color blackKeyLabelColor = Color(0xFFF8FAFC);
  static const Color rulerBackgroundColor = Color(0xFF0F172A);
  static const Color rulerTextColor = Color(0xFFCBD5E1);
  static const Color takeStripBackgroundColor = Color(0xFF0F172A);
  static const Color velocityLaneBackgroundColor = Color(0xFF111827);
  static const Color velocityStemColor = Color(0xFF38BDF8);
  static const Color velocitySelectedStemColor = Color(0xFFFACC15);
  static const Color marqueeColor = Color(0xFF60A5FA);
  static const Color ghostNoteColor = Color(0xFF7DD3FC);
  static const double defaultViewportWidthPx = 960.0;
  static const double defaultViewportHeightPx = 480.0;
  static const double minViewportExtentPx = 1.0;
  static const double minScrollPx = 0.0;
  static const double viewportCenterFraction = 0.5;
  static const double scrollbarThicknessPx = 12.0;
  static const double scrollbarMinThumbExtentPx = 24.0;
  static const double scrollbarTrackPaddingPx = 2.0;
  static const double scrollbarThumbRadiusPx = 4.0;
  static const Color scrollbarTrackColor = Color(0xFF0F172A);
  static const Color scrollbarThumbColor = Color(0xFF475569);
  static const Color scrollbarThumbActiveColor = Color(0xFF64748B);
  static const int minEditableDurationTicks = 1;
  static const int midiOctaveDisplayOffset = 1;
  static const double fullRowHitTestSlopPx = 0.0;
  static const double takeStripBaselineFraction = 0.5;
  static const List<String> pitchClassNames = <String>[
    'C',
    'C#',
    'D',
    'D#',
    'E',
    'F',
    'F#',
    'G',
    'G#',
    'A',
    'A#',
    'B',
  ];
}

/// Centralized audio metering, waveform ring, and tempo validation constants.
abstract final class TelemetryConstants {
  static const double minLinearAmplitude = 0.0;
  static const double maxLinearAmplitude = 1.0;

  /// Aligns directly with `MuseConstants.limiterCeiling`.
  static const double meterClipThresholdLinear = 0.99;

  /// Aligns with `MuseConstants.limiterSoftKneeThreshold`.
  static const double meterWarnThresholdLinear =
      MuseConstants.limiterSoftKneeThreshold;

  /// Muted by default to prevent acoustic feedback unless user raises foldback gain.
  static const double monitorGainDefaultLinear = 0.0;
  static const double monitorGainMaxLinear = 1.0;

  /// `30 seconds * MuseConstants.telemetryPollHz` — bounded circular ring in RAM.
  static const int maxWaveformSamples = 1800;
  static const int bpmMinValid = 20;
  static const int bpmMaxValid = 360;
  static const double meterHeightPx = 10.0;
}

/// Centralized Composition Root & startup error messages.
abstract final class BootstrapConstants {
  static const String appTitle = 'MuseGrid';
  static const String initializingStatusMessage =
      'Initializing MuseGrid storage, engraving fonts, and sound library...';
  static const String missingBravuraFontMessage =
      'Required Bravura SMuFL font metadata failed to load.';
  static const String defaultSoundFontSizeMismatchMessage =
      'Bundled default SoundFont asset byte length does not match expected SHA-256 bundle size.';
  static const String unsupportedPlatformMessage =
      'MuseGrid requires either dart.library.io (Native) or dart.library.js_interop (Web).';
  static const double startupCardMaxWidthPx = 480.0;
  static const double startupContentPaddingPx = 24.0;
  static const double startupElementGapPx = 16.0;
}
