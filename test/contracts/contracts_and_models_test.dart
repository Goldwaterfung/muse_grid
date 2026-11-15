import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/repositories/storage_contracts.dart';

void main() {
  group('Result & MuseErrorCode', () {
    test('defines all 25 expected error codes', () {
      expect(MuseErrorCode.values.length, 25);
      expect(
        MuseErrorCode.values,
        containsAll(<MuseErrorCode>[
          MuseErrorCode.audioDeviceInitFailed,
          MuseErrorCode.microphonePermissionDenied,
          MuseErrorCode.webAudioUserGestureRequired,
          MuseErrorCode.soundFontLoadFailed,
          MuseErrorCode.soundFontTooLargeForWeb,
          MuseErrorCode.soundFontPresetBufferTooSmall,
          MuseErrorCode.webSoundFontLoadWhilePlaying,
          MuseErrorCode.captureBufferOverflow,
          MuseErrorCode.takeLoadFailed,
          MuseErrorCode.takePlaybackBufferUnderrun,
          MuseErrorCode.eventQueueOverflow,
          MuseErrorCode.eventQueueUnderrun,
          MuseErrorCode.missingSoundFontForPart,
          MuseErrorCode.sqliteJournalModeMismatch,
          MuseErrorCode.sqliteConstraintViolation,
          MuseErrorCode.insufficientStorageQuota,
          MuseErrorCode.casPromotionFailed,
          MuseErrorCode.casBlobMissing,
          MuseErrorCode.entityNotFound,
          MuseErrorCode.revisionConflict,
          MuseErrorCode.invalidMusicXmlFormat,
          MuseErrorCode.invalidSoundFontFormat,
          MuseErrorCode.invalidTickRange,
          MuseErrorCode.invalidMidiChannelOrPitch,
          MuseErrorCode.protectedInitialMapEvent,
        ]),
      );
    });

    test('exhaustive switch over Result<T> handles Ok and Err', () {
      const Result<int> okResult = Ok<int>(42);
      const Result<int> errResult = Err<int>(
        MuseError(
          MuseErrorCode.protectedInitialMapEvent,
          'Cannot delete tick 0 event',
          cause: 'tick == 0',
        ),
      );

      final okValue = switch (okResult) {
        Ok(:final value) => value,
        Err() => -1,
      };
      final errCode = switch (errResult) {
        Ok() => null,
        Err(:final error) => error.code,
      };

      expect(okResult.isOk, isTrue);
      expect(okResult.isErr, isFalse);
      expect(okValue, 42);

      expect(errResult.isOk, isFalse);
      expect(errResult.isErr, isTrue);
      expect(errCode, MuseErrorCode.protectedInitialMapEvent);
      expect(
        (errResult as Err<int>).error.toString(),
        contains('protectedInitialMapEvent'),
      );
    });
  });

  group('Branded IDs & Units', () {
    test('zero-cost extension types preserve underlying values', () {
      const projectId = ProjectId('0193a8f0-0000-7000-8000-000000000001');
      const partId = PartId('0193a8f0-0000-7000-8000-000000000002');
      const noteId = NoteId('0193a8f0-0000-7000-8000-000000000003');
      const spannerId = SpannerId('0193a8f0-0000-7000-8000-000000000004');
      const tempoEventId = TempoEventId('0193a8f0-0000-7000-8000-000000000005');
      const timeSigEventId = TimeSigEventId(
        '0193a8f0-0000-7000-8000-000000000006',
      );
      const keySigEventId = KeySigEventId(
        '0193a8f0-0000-7000-8000-000000000007',
      );
      const clefEventId = ClefEventId('0193a8f0-0000-7000-8000-000000000008');
      const takeId = TakeId('0193a8f0-0000-7000-8000-000000000009');
      const sfId = SoundFontId('0193a8f0-0000-7000-8000-00000000000a');
      const profileId = CalibrationProfileId(
        '0193a8f0-0000-7000-8000-00000000000b',
      );
      const digest = Sha256Digest(MuseConstants.defaultSoundFontSha256);
      const tick = Tick(960);
      const frame = SampleFrame(48000);
      const epoch = EpochId(7);
      const sfHandle = SoundFontHandle(1);

      expect(projectId.value, endsWith('0001'));
      expect(partId.value, endsWith('0002'));
      expect(noteId.value, endsWith('0003'));
      expect(spannerId.value, endsWith('0004'));
      expect(tempoEventId.value, endsWith('0005'));
      expect(timeSigEventId.value, endsWith('0006'));
      expect(keySigEventId.value, endsWith('0007'));
      expect(clefEventId.value, endsWith('0008'));
      expect(takeId.value, endsWith('0009'));
      expect(sfId.value, endsWith('000a'));
      expect(profileId.value, endsWith('000b'));
      expect(digest.value.length, 64);
      expect(tick.value, 960);
      expect(frame.value, 48000);
      expect(epoch.value, 7);
      expect(sfHandle.value, 1);
    });
  });

  group('MuseConstants', () {
    test('960 PPQN canonical subdivisions satisfy exact integer ratios', () {
      expect(MuseConstants.ppqn, 960);
      expect(MuseConstants.wholeNoteTicks, 4 * MuseConstants.ppqn);

      // Straight
      expect(MuseConstants.halfNoteTicks, 1920);
      expect(MuseConstants.quarterNoteTicks, 960);
      expect(MuseConstants.eighthNoteTicks, 480);
      expect(MuseConstants.sixteenthNoteTicks, 240);
      expect(MuseConstants.thirtySecondNoteTicks, 120);
      expect(MuseConstants.sixtyFourthNoteTicks, 60);

      // Dotted (3/2 of straight)
      expect(
        MuseConstants.dottedHalfNoteTicks,
        MuseConstants.halfNoteTicks * 3 ~/ 2,
      );
      expect(
        MuseConstants.dottedQuarterNoteTicks,
        MuseConstants.quarterNoteTicks * 3 ~/ 2,
      );
      expect(
        MuseConstants.dottedEighthNoteTicks,
        MuseConstants.eighthNoteTicks * 3 ~/ 2,
      );
      expect(
        MuseConstants.dottedSixteenthNoteTicks,
        MuseConstants.sixteenthNoteTicks * 3 ~/ 2,
      );
      expect(
        MuseConstants.dottedThirtySecondNoteTicks,
        MuseConstants.thirtySecondNoteTicks * 3 ~/ 2,
      );

      // Triplet (2/3 of straight)
      expect(
        MuseConstants.tripletHalfNoteTicks,
        MuseConstants.wholeNoteTicks ~/ 3,
      );
      expect(
        MuseConstants.tripletQuarterNoteTicks,
        MuseConstants.halfNoteTicks ~/ 3,
      );
      expect(
        MuseConstants.tripletEighthNoteTicks,
        MuseConstants.quarterNoteTicks ~/ 3,
      );
      expect(
        MuseConstants.tripletSixteenthNoteTicks,
        MuseConstants.eighthNoteTicks ~/ 3,
      );
      expect(
        MuseConstants.tripletThirtySecondNoteTicks,
        MuseConstants.sixteenthNoteTicks ~/ 3,
      );
    });

    test('bundled default SoundFont metadata stays within Web SF2 limit', () {
      expect(
        MuseConstants.defaultSoundFontAssetPath,
        'assets/sf2/GeneralUser_GS_MuseScore_v1.442.sf2',
      );
      expect(MuseConstants.defaultSoundFontSha256.length, 64);
      expect(MuseConstants.defaultSoundFontByteSize, 31277462);
      expect(
        MuseConstants.defaultSoundFontByteSize,
        lessThanOrEqualTo(MuseConstants.maxWebSoundFontBytes),
      );
      expect(MuseConstants.immediateDispatchFrame, -1);
      expect(MuseConstants.maxMidiChannel, MuseConstants.midiChannelCount - 1);
      expect(MuseConstants.countInMidiChannel, MuseConstants.gmPercussionChannel);
      expect(MuseConstants.neutralPitchBend, 0);
      expect(MuseConstants.defaultPickupTicks, 0);
      expect(
        MuseConstants.maxWebSoundFontBytes,
        MuseConstants.maxWebSoundFontMib * MuseConstants.bytesPerMib,
      );
      expect(
        MuseConstants.minRecordingFreeQuotaBytes,
        MuseConstants.minRecordingFreeQuotaMib * MuseConstants.bytesPerMib,
      );
    });
  });

  group('Bridge Transfer Models & Domain Entities', () {
    test('constructs all bridge transfer classes accurately', () {
      const hw = AudioHardwareInfo(
        sampleRate: 48000,
        inputChannels: 1,
        outputChannels: 2,
        inputBufferFrames: 256,
        outputBufferFrames: 256,
        deviceFingerprint: 'coreaudio:builtin',
      );
      const preset = SoundFontPresetInfo(
        bankNum: 0,
        programNum: 0,
        presetName: 'Stereo Grand',
      );
      const loadedSf = LoadedSoundFontDescriptor(
        handle: SoundFontHandle(1),
        presets: [preset],
      );
      const region = ActiveTakePlaybackRegion(
        takeId: TakeId('take-1'),
        partId: PartId('part-1'),
        wavSha256: Sha256Digest(MuseConstants.defaultSoundFontSha256),
        startSampleFrame: SampleFrame(48000),
        durationFrames: 96000,
        gainDb: -1.5,
        pan: 0.25,
      );
      const midiEvent = ScheduledMidiEvent(
        epoch: EpochId(2),
        targetSampleFrame: SampleFrame(MuseConstants.immediateDispatchFrame),
        type: MuseConstants.midiEventNoteOn,
        channel: 0,
        data1: 60,
        data2: 100,
      );
      const receipt = RecordingCaptureReceipt(
        takeId: TakeId('take-1'),
        stagingPath: '/tmp/rec_take-1.wav.part',
        sha256: Sha256Digest(MuseConstants.defaultSoundFontSha256),
        capturedSampleClock: SampleFrame(100000),
        capturedPlayheadFrame: SampleFrame(48000),
        durationFrames: 48000,
        sampleRate: 48000,
        channelCount: 1,
        outputBufferFrames: 256,
        inputBufferFrames: 256,
      );
      const telemetry = TelemetrySnapshot(
        playheadSampleFrame: SampleFrame(24000),
        activeEpoch: EpochId(2),
        outputPeakL: 0.5,
        outputPeakR: 0.5,
        outputRmsL: 0.25,
        outputRmsR: 0.25,
        inputPeak: 0.1,
        inputRms: 0.05,
        isPlaying: true,
        isCapturing: false,
        hasEventQueueUnderrun: false,
        hasCaptureBufferOverflow: false,
        hasTakePlaybackUnderrun: false,
      );

      expect(hw.sampleRate, 48000);
      expect(loadedSf.presets.single.presetName, 'Stereo Grand');
      expect(region.gainDb, -1.5);
      expect(midiEvent.pitchBend, 0);
      expect(receipt.channelCount, 1);
      expect(telemetry.isPlaying, isTrue);
    });

    test('constructs all domain entities, aggregate, and mutation batch', () {
      const projectId = ProjectId('proj-1');
      const partId = PartId('part-1');
      const noteId = NoteId('note-1');
      const spannerId = SpannerId('span-1');
      const sfId = SoundFontId('sf-1');
      const takeId = TakeId('take-1');
      const digest = Sha256Digest(MuseConstants.defaultSoundFontSha256);

      const summary = ProjectSummary(
        projectId: projectId,
        title: 'Etude in C',
        ppqn: MuseConstants.ppqn,
        gridSnapTicks: MuseConstants.sixteenthNoteTicks,
        pickupTicks: 0,
        playbackTimingMode: PlaybackTimingMode.quantized,
        revision: 1,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      );
      const createInput = CreateProjectInput(
        projectId: projectId,
        title: 'Etude in C',
        gridSnapTicks: MuseConstants.sixteenthNoteTicks,
        initialUsPerQuarter: 500000,
        initialTimeSigNumerator: 4,
        initialTimeSigDenominator: 4,
      );
      const metadataUpdate = UpdateProjectMetadataInput(
        projectId: projectId,
        expectedRevision: 1,
        title: 'Etude in C Major',
      );
      const part = ProjectPartEntity(
        partId: partId,
        projectId: projectId,
        musicXmlPartId: 'P1',
        sortOrder: 0,
        name: 'Piano',
        stavesCount: 2,
        midiChannel: 0,
        sfId: sfId,
        bankNum: 0,
        programNum: 0,
        gainDb: 0.0,
        pan: 0.0,
        isMuted: false,
        isSolo: false,
        updatedAtMs: 1000,
      );
      const tempo = TempoEventEntity(
        tempoEventId: TempoEventId('tempo-0'),
        projectId: projectId,
        tick: Tick(0),
        usPerQuarter: 500000,
        updatedAtMs: 1000,
      );
      const timeSig = TimeSignatureEventEntity(
        tsEventId: TimeSigEventId('ts-0'),
        projectId: projectId,
        tick: Tick(0),
        numerator: 4,
        denominator: 4,
        updatedAtMs: 1000,
      );
      const keySig = KeySignatureEventEntity(
        keyEventId: KeySigEventId('key-0'),
        projectId: projectId,
        partId: null,
        staffNumber: 0,
        tick: Tick(0),
        fifths: 0,
        mode: KeyMode.major,
        updatedAtMs: 1000,
      );
      const clef = ClefEventEntity(
        clefEventId: ClefEventId('clef-0'),
        projectId: projectId,
        partId: partId,
        staffNumber: 1,
        tick: Tick(0),
        sign: ClefSign.G,
        line: 2,
        octaveChange: 0,
        updatedAtMs: 1000,
      );
      const note = TimelineNote(
        noteId: noteId,
        projectId: projectId,
        partId: partId,
        staffNumber: 1,
        voiceNumber: 1,
        pitchMidi: 60,
        enharmonicStep: EnharmonicStep.C,
        enharmonicAlter: 0,
        rawStartTick: Tick(12),
        rawDurationTicks: 950,
        quantizedStartTick: Tick(0),
        quantizedDurationTicks: MuseConstants.quarterNoteTicks,
        velocity: 96,
        updatedAtMs: 1000,
      );
      const spanner = NoteSpannerEntity(
        spannerId: spannerId,
        projectId: projectId,
        partId: partId,
        spannerType: SpannerType.slur,
        startNoteId: noteId,
        endNoteId: noteId,
        spannerLevel: 1,
        placement: SpannerPlacement.auto,
        updatedAtMs: 1000,
      );
      const take = AudioTakeEntity(
        takeId: takeId,
        projectId: projectId,
        partId: partId,
        blobSha256: digest,
        startTick: Tick(0),
        sampleRate: 48000,
        channelCount: 1,
        durationFrames: 48000,
        capturedPlayheadFrame: SampleFrame(512),
        capturedSampleClock: SampleFrame(10000),
        outputBufferFrames: 256,
        inputBufferFrames: 256,
        calibrationOffsetFrames: 0,
        createdAtMs: 1000,
        updatedAtMs: 1000,
      );
      const sfCatalog = SoundFontCatalogEntry(
        sfId: sfId,
        name: MuseConstants.defaultSoundFontDisplayName,
        blobSha256: digest,
        byteSize: MuseConstants.defaultSoundFontByteSize,
        presets: [
          SoundFontPresetInfo(
            bankNum: 0,
            programNum: 0,
            presetName: 'Stereo Grand',
          ),
        ],
        createdAtMs: 1000,
        updatedAtMs: 1000,
      );
      const calibration = LatencyCalibrationProfile(
        profileId: CalibrationProfileId('cal-1'),
        platform: CalibrationPlatform.macos,
        deviceFingerprint: 'coreaudio:builtin',
        sampleRate: 48000,
        bufferSizeFrames: 256,
        calibrationOffsetFrames: -12,
        updatedAtMs: 1000,
      );
      const upsertCal = UpsertCalibrationProfileInput(
        platform: CalibrationPlatform.macos,
        deviceFingerprint: 'coreaudio:builtin',
        sampleRate: 48000,
        bufferSizeFrames: 256,
        calibrationOffsetFrames: -12,
      );
      const picked = PickedExternalFile(
        fileName: 'score.musicxml',
        extension: 'musicxml',
        byteLength: 1024,
        byteStream: Stream<List<int>>.empty(),
      );
      const realign = AudioTakeRealignmentUpdate(
        takeId: takeId,
        newStartTick: Tick(15),
        newCalibrationOffsetFrames: -12,
      );
      const aggregate = ProjectWorkspaceAggregate(
        project: summary,
        parts: [part],
        tempoEvents: [tempo],
        timeSignatureEvents: [timeSig],
        keySignatureEvents: [keySig],
        clefEvents: [clef],
        notes: [note],
        spanners: [spanner],
        audioTakes: [take],
      );
      const batch = ScoreMutationBatch(
        projectId: projectId,
        expectedRevision: 1,
        projectMetadataUpdate: metadataUpdate,
        upsertNotes: [note],
      );

      expect(createInput.pickupTicks, 0);
      expect(createInput.playbackTimingMode, PlaybackTimingMode.quantized);
      expect(aggregate.parts.single.stavesCount, 2);
      expect(aggregate.notes.single.pitchMidi, 60);
      expect(sfCatalog.presets.length, 1);
      expect(calibration.calibrationOffsetFrames, -12);
      expect(upsertCal.platform, CalibrationPlatform.macos);
      expect(picked.extension, 'musicxml');
      expect(realign.newStartTick.value, 15);
      expect(batch.upsertNotes.length, 1);
      expect(batch.deleteNoteIds, isEmpty);

      // Verify repository interface symbols are visible from pure Dart contracts.
      expect(IStorageMaintenanceRepository, isNotNull);
      expect(IProjectRepository, isNotNull);
      expect(IAssetLibraryRepository, isNotNull);
      expect(IExternalFileExchange, isNotNull);
      expect(IInternalStorageLocator, isNotNull);
      expect(IAudioLifecycleBridge, isNotNull);
      expect(ITransportBridge, isNotNull);
      expect(ISynthEventBridge, isNotNull);
      expect(IRecordingBridge, isNotNull);
      expect(ITelemetryBridge, isNotNull);
    });
  });
}
