import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:muse_grid/bridge/contracts/audio_bridge_contracts.dart';
import 'package:muse_grid/bridge/contracts/engine_constants.dart';
import 'package:muse_grid/bridge/contracts/ids_and_units.dart';
import 'package:muse_grid/bridge/contracts/result.dart';
import 'package:muse_grid/domain/assets/soundfont_preset_parser.dart';
import 'package:muse_grid/domain/commands/score_editing_command_bus.dart';
import 'package:muse_grid/domain/models/score_models.dart';
import 'package:muse_grid/domain/notation/dual_model_score_service.dart';
import 'package:muse_grid/domain/playback/lookahead_playback_coordinator.dart';
import 'package:muse_grid/domain/recording/recording_session_coordinator.dart';
import 'package:muse_grid/domain/repositories/storage_contracts.dart';
import 'package:muse_grid/presentation/controllers/audio_session_contract.dart';
import 'package:muse_grid/presentation/controllers/project_catalog_controller.dart';
import 'package:muse_grid/presentation/controllers/transport_and_telemetry_controller.dart';
import 'package:muse_grid/presentation/controllers/workspace_shell_controller.dart';
import 'package:muse_grid/presentation/theme/muse_presentation_constants.dart';

// ---------------------------------------------------------------------------
// Minimal Pure Dart SF2 & MusicXML Helpers
// ---------------------------------------------------------------------------

Uint8List _ascii(String text) => Uint8List.fromList(ascii.encode(text));

Uint8List _riffChunk(String fourCc, Uint8List payload) {
  final pad = payload.length.isOdd ? 1 : 0;
  final out = Uint8List(8 + payload.length + pad);
  out.setRange(0, 4, _ascii(fourCc));
  ByteData.sublistView(out).setUint32(4, payload.length, Endian.little);
  out.setRange(8, 8 + payload.length, payload);
  return out;
}

Uint8List _riffList(String listType, List<Uint8List> subchunks) {
  var bodyLength = 4;
  for (final sub in subchunks) {
    bodyLength += sub.length;
  }
  final body = Uint8List(bodyLength);
  body.setRange(0, 4, _ascii(listType));
  var offset = 4;
  for (final sub in subchunks) {
    body.setRange(offset, offset + sub.length, sub);
    offset += sub.length;
  }
  return _riffChunk('LIST', body);
}

Uint8List _phdrRecord(String name, int programNum, int bankNum) {
  final rec = Uint8List(38);
  final nameBytes = latin1.encode(name);
  final copyLen = nameBytes.length > 20 ? 20 : nameBytes.length;
  rec.setRange(0, copyLen, nameBytes);
  final view = ByteData.sublistView(rec);
  view.setUint16(20, programNum, Endian.little);
  view.setUint16(22, bankNum, Endian.little);
  return rec;
}

Uint8List _buildMinimalSf2({
  List<SoundFontPresetInfo> presets = const <SoundFontPresetInfo>[
    SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Grand Piano'),
    SoundFontPresetInfo(bankNum: 128, programNum: 0, presetName: 'Standard Kit'),
  ],
}) {
  final totalRecords = presets.length + 1;
  final phdrBytes = Uint8List(totalRecords * 38);
  for (var i = 0; i < presets.length; i++) {
    final p = presets[i];
    phdrBytes.setRange(
      i * 38,
      (i + 1) * 38,
      _phdrRecord(p.presetName, p.programNum, p.bankNum),
    );
  }
  phdrBytes.setRange(
    presets.length * 38,
    totalRecords * 38,
    _phdrRecord('EOP', 255, 255),
  );
  final pdta = _riffList('pdta', <Uint8List>[
    _riffChunk('phdr', phdrBytes),
    _riffChunk('pbag', Uint8List(4)),
  ]);
  final bodyBytes = 4 + pdta.length;
  final out = Uint8List(8 + bodyBytes);
  out.setRange(0, 4, _ascii('RIFF'));
  ByteData.sublistView(out).setUint32(4, bodyBytes, Endian.little);
  out.setRange(8, 12, _ascii('sfbk'));
  out.setRange(12, out.length, pdta);
  return out;
}

// ---------------------------------------------------------------------------
// In-Memory Pure Dart Contract Fakes
// ---------------------------------------------------------------------------

final class _FakeAudioSessionController implements IAudioSessionController {
  final AudioHardwareInfo _defaultHardwareInfo;

  @override
  final ValueNotifier<AudioSessionStatus> audioSessionStatus;

  @override
  CalibrationPlatform currentPlatform;

  Result<AudioHardwareInfo>? nextInitResult;
  int initializeCalls = 0;

  _FakeAudioSessionController({
    AudioSessionStatus initialStatus = const AudioSessionStatus(
      phase: AudioSessionPhase.ready,
      hardwareInfo: AudioHardwareInfo(
        sampleRate: 48000,
        inputChannels: 1,
        outputChannels: 2,
        inputBufferFrames: 128,
        outputBufferFrames: 256,
        deviceFingerprint: 'mac-coreaudio-0',
      ),
    ),
  }) : _defaultHardwareInfo =
           initialStatus.hardwareInfo ??
           const AudioHardwareInfo(
             sampleRate: 48000,
             inputChannels: 1,
             outputChannels: 2,
             inputBufferFrames: 128,
             outputBufferFrames: 256,
             deviceFingerprint: 'mac-coreaudio-0',
           ),
       currentPlatform = CalibrationPlatform.macos,
       audioSessionStatus = ValueNotifier<AudioSessionStatus>(initialStatus);

  @override
  Future<Result<AudioHardwareInfo>> ensureAudioInitialized() async {
    initializeCalls += 1;
    final override = nextInitResult;
    if (override != null) {
      if (override case Ok<AudioHardwareInfo>(:final value)) {
        audioSessionStatus.value = AudioSessionStatus(
          phase: AudioSessionPhase.ready,
          hardwareInfo: value,
        );
      } else if (override case Err<AudioHardwareInfo>(:final error)) {
        audioSessionStatus.value = AudioSessionStatus(
          phase: AudioSessionPhase.failed,
          error: error,
        );
      }
      return override;
    }
    audioSessionStatus.value = AudioSessionStatus(
      phase: AudioSessionPhase.ready,
      hardwareInfo: _defaultHardwareInfo,
    );
    return Ok(_defaultHardwareInfo);
  }

  void dispose() {
    audioSessionStatus.dispose();
  }
}

final class _FakeStorageMaintenanceRepository
    implements IStorageMaintenanceRepository {
  int availableQuotaBytes = 500 * 1024 * 1024;
  int reclaimedOnGc = 3;
  final List<int> gcCutoffs = <int>[];
  MuseError? nextQuotaError;

  @override
  Future<Result<void>> initializeAndVerifyStorage() async => const Ok(null);

  @override
  Future<Result<int>> verifyAvailableQuotaBytes({
    required int requiredBytes,
  }) async {
    if (nextQuotaError != null) {
      return Err(nextQuotaError!);
    }
    if (availableQuotaBytes < requiredBytes) {
      return Err(
        MuseError(
          MuseErrorCode.insufficientStorageQuota,
          'Need $requiredBytes bytes, only $availableQuotaBytes available.',
        ),
      );
    }
    return Ok(availableQuotaBytes);
  }

  @override
  Future<Result<int>> runGarbageCollection({
    required int olderThanEpochMs,
  }) async {
    gcCutoffs.add(olderThanEpochMs);
    return Ok(reclaimedOnGc);
  }

  @override
  Future<void> close() async {}
}

final class _FakeAssetLibraryRepository implements IAssetLibraryRepository {
  final Map<SoundFontId, SoundFontCatalogEntry> _soundFonts =
      <SoundFontId, SoundFontCatalogEntry>{};
  final Map<String, LatencyCalibrationProfile> _calibrations =
      <String, LatencyCalibrationProfile>{};
  final _FakeProjectRepository? linkedProjectRepository;

  int _sfCounter = 0;
  int _calCounter = 0;
  int _clock = 1000;

  _FakeAssetLibraryRepository({this.linkedProjectRepository});

  void seedSoundFont(SoundFontCatalogEntry entry) {
    _soundFonts[entry.sfId] = entry;
  }

  @override
  Future<Result<List<SoundFontCatalogEntry>>> listActiveSoundFonts() async {
    return Ok(List<SoundFontCatalogEntry>.unmodifiable(_soundFonts.values));
  }

  @override
  Future<Result<SoundFontCatalogEntry>> importSoundFontBytes({
    required String displayName,
    required Stream<List<int>> byteStream,
    required int byteLength,
    required List<SoundFontPresetInfo> extractedPresets,
  }) async {
    final collected = <int>[];
    await for (final chunk in byteStream) {
      collected.addAll(chunk);
    }
    if (collected.length != byteLength) {
      return Err(
        MuseError(
          MuseErrorCode.invalidSoundFontFormat,
          'Stream byte count ${collected.length} != $byteLength.',
        ),
      );
    }
    _sfCounter += 1;
    _clock += 10;
    final entry = SoundFontCatalogEntry(
      sfId: SoundFontId('sf-$_sfCounter'),
      name: displayName,
      blobSha256: Sha256Digest('a' * 63 + '$_sfCounter'),
      byteSize: byteLength,
      presets: List<SoundFontPresetInfo>.unmodifiable(extractedPresets),
      createdAtMs: _clock,
      updatedAtMs: _clock,
    );
    _soundFonts[entry.sfId] = entry;
    return Ok(entry);
  }

  @override
  Future<Result<void>> softDeleteSoundFont(
    SoundFontId sfId, {
    required int deletedAtMs,
  }) async {
    if (_soundFonts.remove(sfId) == null) {
      return Err(
        MuseError(
          MuseErrorCode.entityNotFound,
          'SoundFont "${sfId.value}" not found.',
        ),
      );
    }
    linkedProjectRepository?.nullifySoundFontReferences(sfId);
    return const Ok(null);
  }

  String _calKey(
    CalibrationPlatform platform,
    String deviceFingerprint,
    int sampleRate,
    int bufferSizeFrames,
  ) =>
      '${platform.name}|$deviceFingerprint|$sampleRate|$bufferSizeFrames';

  @override
  Future<Result<LatencyCalibrationProfile?>> getCalibrationProfile({
    required CalibrationPlatform platform,
    required String deviceFingerprint,
    required int sampleRate,
    required int bufferSizeFrames,
  }) async {
    return Ok(
      _calibrations[_calKey(
        platform,
        deviceFingerprint,
        sampleRate,
        bufferSizeFrames,
      )],
    );
  }

  @override
  Future<Result<LatencyCalibrationProfile>> upsertCalibrationProfile(
    UpsertCalibrationProfileInput input,
  ) async {
    _calCounter += 1;
    _clock += 10;
    final key = _calKey(
      input.platform,
      input.deviceFingerprint,
      input.sampleRate,
      input.bufferSizeFrames,
    );
    final profile = LatencyCalibrationProfile(
      profileId: _calibrations[key]?.profileId ??
          CalibrationProfileId('cal-$_calCounter'),
      platform: input.platform,
      deviceFingerprint: input.deviceFingerprint,
      sampleRate: input.sampleRate,
      bufferSizeFrames: input.bufferSizeFrames,
      calibrationOffsetFrames: input.calibrationOffsetFrames,
      updatedAtMs: _clock,
    );
    _calibrations[key] = profile;
    return Ok(profile);
  }
}

final class _FakeProjectRepository implements IProjectRepository {
  final Map<ProjectId, ProjectWorkspaceAggregate> _projects =
      <ProjectId, ProjectWorkspaceAggregate>{};
  final Set<ProjectId> _deleted = <ProjectId>{};
  int _idSeq = 0;
  int _clock = 1000;

  void seedProject(ProjectWorkspaceAggregate agg) {
    _projects[agg.project.projectId] = agg;
  }

  void nullifySoundFontReferences(SoundFontId sfId) {
    for (final entry in _projects.entries.toList()) {
      final agg = entry.value;
      var changed = false;
      final updatedParts = agg.parts
          .map((part) {
            if (part.sfId != sfId) {
              return part;
            }
            changed = true;
            return ProjectPartEntity(
              partId: part.partId,
              projectId: part.projectId,
              musicXmlPartId: part.musicXmlPartId,
              sortOrder: part.sortOrder,
              name: part.name,
              stavesCount: part.stavesCount,
              midiChannel: part.midiChannel,
              sfId: null,
              bankNum: part.bankNum,
              programNum: part.programNum,
              gainDb: part.gainDb,
              pan: part.pan,
              isMuted: part.isMuted,
              isSolo: part.isSolo,
              updatedAtMs: part.updatedAtMs,
            );
          })
          .toList(growable: false);
      if (changed) {
        _projects[entry.key] = ProjectWorkspaceAggregate(
          project: agg.project,
          parts: updatedParts,
          tempoEvents: agg.tempoEvents,
          timeSignatureEvents: agg.timeSignatureEvents,
          keySignatureEvents: agg.keySignatureEvents,
          clefEvents: agg.clefEvents,
          notes: agg.notes,
          spanners: agg.spanners,
          audioTakes: agg.audioTakes,
        );
      }
    }
  }

  @override
  Future<Result<List<ProjectSummary>>> listActiveProjects({
    required int limit,
    required int offset,
  }) async {
    final active = _projects.values
        .where((agg) => !_deleted.contains(agg.project.projectId))
        .map((agg) => agg.project)
        .toList()
      ..sort((a, b) => b.updatedAtMs.compareTo(a.updatedAtMs));
    if (offset >= active.length) {
      return const Ok(<ProjectSummary>[]);
    }
    final end = (offset + limit) > active.length ? active.length : offset + limit;
    return Ok(List<ProjectSummary>.unmodifiable(active.sublist(offset, end)));
  }

  @override
  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(
    ProjectId projectId,
  ) async {
    if (_deleted.contains(projectId) || !_projects.containsKey(projectId)) {
      return Err(
        MuseError(
          MuseErrorCode.entityNotFound,
          'Project "${projectId.value}" not found.',
        ),
      );
    }
    return Ok(_projects[projectId]!);
  }

  @override
  Future<Result<ProjectSummary>> createProject(CreateProjectInput input) async {
    if (_projects.containsKey(input.projectId)) {
      return Err(
        MuseError(
          MuseErrorCode.sqliteConstraintViolation,
          'Duplicate projectId "${input.projectId.value}".',
        ),
      );
    }
    _clock += 100;
    _idSeq += 1;
    final defaultPartId = PartId('seeded-part-$_idSeq');
    final summary = ProjectSummary(
      projectId: input.projectId,
      title: input.title,
      ppqn: MuseConstants.ppqn,
      gridSnapTicks: input.gridSnapTicks,
      pickupTicks: input.pickupTicks,
      playbackTimingMode: input.playbackTimingMode,
      revision: 0,
      createdAtMs: _clock,
      updatedAtMs: _clock,
    );
    _projects[input.projectId] = ProjectWorkspaceAggregate(
      project: summary,
      parts: <ProjectPartEntity>[
        ProjectPartEntity(
          partId: defaultPartId,
          projectId: input.projectId,
          musicXmlPartId: 'P1',
          sortOrder: 0,
          name: 'Part 1',
          stavesCount: 1,
          midiChannel: 0,
          sfId: null,
          bankNum: 0,
          programNum: 0,
          gainDb: 0.0,
          pan: 0.0,
          isMuted: false,
          isSolo: false,
          updatedAtMs: _clock,
        ),
      ],
      tempoEvents: <TempoEventEntity>[
        TempoEventEntity(
          tempoEventId: TempoEventId('seeded-tempo-$_idSeq'),
          projectId: input.projectId,
          tick: const Tick(0),
          usPerQuarter: input.initialUsPerQuarter,
          updatedAtMs: _clock,
        ),
      ],
      timeSignatureEvents: <TimeSignatureEventEntity>[
        TimeSignatureEventEntity(
          tsEventId: TimeSigEventId('seeded-ts-$_idSeq'),
          projectId: input.projectId,
          tick: const Tick(0),
          numerator: input.initialTimeSigNumerator,
          denominator: input.initialTimeSigDenominator,
          updatedAtMs: _clock,
        ),
      ],
      keySignatureEvents: <KeySignatureEventEntity>[
        KeySignatureEventEntity(
          keyEventId: KeySigEventId('seeded-key-$_idSeq'),
          projectId: input.projectId,
          partId: null,
          staffNumber: 0,
          tick: const Tick(0),
          fifths: 0,
          mode: KeyMode.major,
          updatedAtMs: _clock,
        ),
      ],
      clefEvents: <ClefEventEntity>[
        ClefEventEntity(
          clefEventId: ClefEventId('seeded-clef-$_idSeq'),
          projectId: input.projectId,
          partId: defaultPartId,
          staffNumber: 1,
          tick: const Tick(0),
          sign: ClefSign.G,
          line: 2,
          octaveChange: 0,
          updatedAtMs: _clock,
        ),
      ],
      notes: const <TimelineNote>[],
      spanners: const <NoteSpannerEntity>[],
      audioTakes: const <AudioTakeEntity>[],
    );
    return Ok(summary);
  }

  @override
  Future<Result<void>> updateProjectMetadata(
    UpdateProjectMetadataInput input,
  ) async {
    final agg = _projects[input.projectId];
    if (agg == null || _deleted.contains(input.projectId)) {
      return const Err(
        MuseError(MuseErrorCode.entityNotFound, 'Project not found.'),
      );
    }
    if (agg.project.revision != input.expectedRevision) {
      return const Err(
        MuseError(MuseErrorCode.revisionConflict, 'Revision conflict.'),
      );
    }
    _clock += 10;
    final nextSummary = ProjectSummary(
      projectId: agg.project.projectId,
      title: input.title ?? agg.project.title,
      ppqn: agg.project.ppqn,
      gridSnapTicks: input.gridSnapTicks ?? agg.project.gridSnapTicks,
      pickupTicks: input.pickupTicks ?? agg.project.pickupTicks,
      playbackTimingMode:
          input.playbackTimingMode ?? agg.project.playbackTimingMode,
      revision: agg.project.revision + 1,
      createdAtMs: agg.project.createdAtMs,
      updatedAtMs: _clock,
    );
    _projects[input.projectId] = ProjectWorkspaceAggregate(
      project: nextSummary,
      parts: agg.parts,
      tempoEvents: agg.tempoEvents,
      timeSignatureEvents: agg.timeSignatureEvents,
      keySignatureEvents: agg.keySignatureEvents,
      clefEvents: agg.clefEvents,
      notes: agg.notes,
      spanners: agg.spanners,
      audioTakes: agg.audioTakes,
    );
    return const Ok(null);
  }

  @override
  Future<Result<void>> softDeleteProject(
    ProjectId projectId, {
    required int deletedAtMs,
  }) async {
    if (!_projects.containsKey(projectId) || _deleted.contains(projectId)) {
      return const Err(
        MuseError(MuseErrorCode.entityNotFound, 'Project not found.'),
      );
    }
    _deleted.add(projectId);
    return const Ok(null);
  }

  @override
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch) async {
    final agg = _projects[batch.projectId];
    if (agg == null || _deleted.contains(batch.projectId)) {
      return const Err(
        MuseError(MuseErrorCode.entityNotFound, 'Project not found.'),
      );
    }
    if (agg.project.revision != batch.expectedRevision) {
      return const Err(
        MuseError(MuseErrorCode.revisionConflict, 'Revision mismatch.'),
      );
    }

    // Deletions run before upserts, matching SqlProjectBatchExecutor.
    final parts = {for (final p in agg.parts) p.partId: p};
    for (final id in batch.deletePartIds) {
      parts.remove(id);
    }
    for (final p in batch.upsertParts) {
      final collision = parts.values.any(
        (existing) =>
            existing.partId != p.partId &&
            existing.musicXmlPartId == p.musicXmlPartId,
      );
      if (collision) {
        return Err(
          MuseError(
            MuseErrorCode.sqliteConstraintViolation,
            'UNIQUE (project_id, musicxml_part_id) collision on "${p.musicXmlPartId}".',
          ),
        );
      }
      parts[p.partId] = p;
    }

    final tempos = {for (final t in agg.tempoEvents) t.tempoEventId: t};
    for (final id in batch.deleteTempoEventIds) {
      tempos.remove(id);
    }
    for (final t in batch.upsertTempoEvents) {
      tempos[t.tempoEventId] = t;
    }

    final timeSigs = {for (final ts in agg.timeSignatureEvents) ts.tsEventId: ts};
    for (final id in batch.deleteTimeSignatureEventIds) {
      timeSigs.remove(id);
    }
    for (final ts in batch.upsertTimeSignatureEvents) {
      timeSigs[ts.tsEventId] = ts;
    }

    final keySigs = {for (final k in agg.keySignatureEvents) k.keyEventId: k};
    for (final id in batch.deleteKeySignatureEventIds) {
      keySigs.remove(id);
    }
    for (final k in batch.upsertKeySignatureEvents) {
      final globalCollision = k.partId == null &&
          keySigs.values.any(
            (existing) =>
                existing.keyEventId != k.keyEventId &&
                existing.partId == null &&
                existing.tick.value == k.tick.value,
          );
      if (globalCollision) {
        return const Err(
          MuseError(
            MuseErrorCode.sqliteConstraintViolation,
            'Global key signature tick collision.',
          ),
        );
      }
      keySigs[k.keyEventId] = k;
    }

    final clefs = {for (final c in agg.clefEvents) c.clefEventId: c};
    for (final id in batch.deleteClefEventIds) {
      clefs.remove(id);
    }
    for (final c in batch.upsertClefEvents) {
      clefs[c.clefEventId] = c;
    }

    final notes = {for (final n in agg.notes) n.noteId: n};
    for (final id in batch.deleteNoteIds) {
      notes.remove(id);
    }
    for (final n in batch.upsertNotes) {
      notes[n.noteId] = n;
    }

    final spanners = {for (final s in agg.spanners) s.spannerId: s};
    for (final id in batch.deleteSpannerIds) {
      spanners.remove(id);
    }
    for (final s in batch.upsertSpanners) {
      spanners[s.spannerId] = s;
    }

    final takes = {for (final a in agg.audioTakes) a.partId: a};
    for (final pid in batch.deleteAudioTakePartIds) {
      takes.remove(pid);
    }
    for (final a in batch.upsertAudioTakes) {
      takes[a.partId] = a;
    }

    _clock += 10;
    final nextRevision = agg.project.revision + 1;
    final nextSummary = ProjectSummary(
      projectId: agg.project.projectId,
      title: batch.projectMetadataUpdate?.title ?? agg.project.title,
      ppqn: agg.project.ppqn,
      gridSnapTicks:
          batch.projectMetadataUpdate?.gridSnapTicks ??
          agg.project.gridSnapTicks,
      pickupTicks:
          batch.projectMetadataUpdate?.pickupTicks ?? agg.project.pickupTicks,
      playbackTimingMode:
          batch.projectMetadataUpdate?.playbackTimingMode ??
          agg.project.playbackTimingMode,
      revision: nextRevision,
      createdAtMs: agg.project.createdAtMs,
      updatedAtMs: _clock,
    );

    _projects[batch.projectId] = ProjectWorkspaceAggregate(
      project: nextSummary,
      parts: parts.values.toList()..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
      tempoEvents: tempos.values.toList()
        ..sort((a, b) => a.tick.value.compareTo(b.tick.value)),
      timeSignatureEvents: timeSigs.values.toList()
        ..sort((a, b) => a.tick.value.compareTo(b.tick.value)),
      keySignatureEvents: keySigs.values.toList()
        ..sort((a, b) => a.tick.value.compareTo(b.tick.value)),
      clefEvents: clefs.values.toList()
        ..sort((a, b) => a.tick.value.compareTo(b.tick.value)),
      notes: notes.values.toList(),
      spanners: spanners.values.toList(),
      audioTakes: takes.values.toList(),
    );
    return Ok(nextRevision);
  }

  @override
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  }) async {
    final agg = _projects[projectId]!;
    _clock += 10;
    final take = AudioTakeEntity(
      takeId: receipt.takeId,
      projectId: projectId,
      partId: partId,
      blobSha256: receipt.sha256,
      startTick: alignedStartTick,
      sampleRate: receipt.sampleRate,
      channelCount: receipt.channelCount,
      durationFrames: receipt.durationFrames,
      capturedPlayheadFrame: receipt.capturedPlayheadFrame,
      capturedSampleClock: receipt.capturedSampleClock,
      outputBufferFrames: receipt.outputBufferFrames,
      inputBufferFrames: receipt.inputBufferFrames,
      calibrationOffsetFrames: calibrationOffsetFrames,
      createdAtMs: _clock,
      updatedAtMs: _clock,
    );
    final updatedTakes = [
      ...agg.audioTakes.where((t) => t.partId != partId),
      take,
    ];
    _projects[projectId] = ProjectWorkspaceAggregate(
      project: agg.project,
      parts: agg.parts,
      tempoEvents: agg.tempoEvents,
      timeSignatureEvents: agg.timeSignatureEvents,
      keySignatureEvents: agg.keySignatureEvents,
      clefEvents: agg.clefEvents,
      notes: agg.notes,
      spanners: agg.spanners,
      audioTakes: updatedTakes,
    );
    return Ok(take);
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  }) async {
    final agg = _projects[projectId]!;
    final byId = {for (final u in updates) u.takeId: u};
    final updated = agg.audioTakes.map((t) {
      final u = byId[t.takeId];
      if (u == null) return t;
      return AudioTakeEntity(
        takeId: t.takeId,
        projectId: t.projectId,
        partId: t.partId,
        blobSha256: t.blobSha256,
        startTick: u.newStartTick,
        sampleRate: t.sampleRate,
        channelCount: t.channelCount,
        durationFrames: t.durationFrames,
        capturedPlayheadFrame: t.capturedPlayheadFrame,
        capturedSampleClock: t.capturedSampleClock,
        outputBufferFrames: t.outputBufferFrames,
        inputBufferFrames: t.inputBufferFrames,
        calibrationOffsetFrames: u.newCalibrationOffsetFrames,
        createdAtMs: t.createdAtMs,
        updatedAtMs: _clock,
      );
    }).toList(growable: false);
    _projects[projectId] = ProjectWorkspaceAggregate(
      project: agg.project,
      parts: agg.parts,
      tempoEvents: agg.tempoEvents,
      timeSignatureEvents: agg.timeSignatureEvents,
      keySignatureEvents: agg.keySignatureEvents,
      clefEvents: agg.clefEvents,
      notes: agg.notes,
      spanners: agg.spanners,
      audioTakes: updated,
    );
    return Ok(updated);
  }

  @override
  Future<Result<void>> deletePartAudioTake({
    required ProjectId projectId,
    required PartId partId,
  }) async {
    final agg = _projects[projectId];
    if (agg == null) {
      return const Err(
        MuseError(MuseErrorCode.entityNotFound, 'Project not found.'),
      );
    }
    _projects[projectId] = ProjectWorkspaceAggregate(
      project: agg.project,
      parts: agg.parts,
      tempoEvents: agg.tempoEvents,
      timeSignatureEvents: agg.timeSignatureEvents,
      keySignatureEvents: agg.keySignatureEvents,
      clefEvents: agg.clefEvents,
      notes: agg.notes,
      spanners: agg.spanners,
      audioTakes:
          agg.audioTakes.where((t) => t.partId != partId).toList(growable: false),
    );
    return const Ok(null);
  }
}

final class _FakeExternalFileExchange implements IExternalFileExchange {
  PickedExternalFile? nextPickedFile;
  final List<({String suggestedFileName, String mimeType, List<int> bytes})>
  exportedFiles =
      <({String suggestedFileName, String mimeType, List<int> bytes})>[];
  final List<({Sha256Digest wavSha256, String suggestedFileName})>
  exportedWavTakes =
      <({Sha256Digest wavSha256, String suggestedFileName})>[];

  @override
  Future<Result<PickedExternalFile?>> pickImportFile({
    required List<String> allowedExtensions,
  }) async => Ok(nextPickedFile);

  @override
  Future<Result<void>> exportFileToUser({
    required String suggestedFileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    exportedFiles.add((
      suggestedFileName: suggestedFileName,
      mimeType: mimeType,
      bytes: bytes,
    ));
    return const Ok(null);
  }

  @override
  Future<Result<void>> exportCasWavTakeToUser({
    required Sha256Digest wavSha256,
    required String suggestedFileName,
  }) async {
    exportedWavTakes.add((
      wavSha256: wavSha256,
      suggestedFileName: suggestedFileName,
    ));
    return const Ok(null);
  }
}

final class _FakeAudioBridge
    implements
        IAudioLifecycleBridge,
        ITransportBridge,
        ISynthEventBridge,
        IRecordingBridge,
        ITelemetryBridge {
  AudioHardwareInfo hardwareInfo = const AudioHardwareInfo(
    sampleRate: 48000,
    inputChannels: 1,
    outputChannels: 2,
    inputBufferFrames: 128,
    outputBufferFrames: 256,
    deviceFingerprint: 'mac-coreaudio-0',
  );

  EpochId _epoch = const EpochId(1);
  int _sfHandleSeq = 0;
  final Map<Sha256Digest, SoundFontHandle> loadedSfs =
      <Sha256Digest, SoundFontHandle>{};
  final List<SoundFontHandle> unloadedHandles = <SoundFontHandle>[];
  final List<ScheduledMidiEvent> scheduledEvents = <ScheduledMidiEvent>[];
  final List<TelemetrySnapshot> queuedTelemetry = <TelemetrySnapshot>[];
  TelemetrySnapshot? _latestSnapshot;

  @override
  AudioHardwareInfo get currentHardwareInfo => hardwareInfo;

  @override
  Future<Result<AudioHardwareInfo>> initialize() async => Ok(hardwareInfo);

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  }) async {
    _sfHandleSeq += 1;
    final handle = SoundFontHandle(_sfHandleSeq);
    loadedSfs[sha256] = handle;
    return Ok(
      LoadedSoundFontDescriptor(
        handle: handle,
        presets: const <SoundFontPresetInfo>[
          SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Piano'),
          SoundFontPresetInfo(
            bankNum: 128,
            programNum: 0,
            presetName: 'Standard Kit',
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<void>> unloadSoundFont(SoundFontHandle handle) async {
    unloadedHandles.add(handle);
    return const Ok(null);
  }

  @override
  Future<void> dispose() async {}

  @override
  Result<void> play() => const Ok(null);

  @override
  Result<void> pause() => const Ok(null);

  @override
  Result<void> stop() => const Ok(null);

  @override
  Result<EpochId> seekToSample(SampleFrame targetFrame) {
    _epoch = EpochId(_epoch.value + 1);
    return Ok(_epoch);
  }

  ({bool enabled, SampleFrame start, SampleFrame end})? lastLoopRegion;

  @override
  Result<void> setLoopRegion({
    required bool enabled,
    required SampleFrame startFrame,
    required SampleFrame endFrame,
  }) {
    lastLoopRegion = (enabled: enabled, start: startFrame, end: endFrame);
    return const Ok(null);
  }

  @override
  Future<Result<void>> syncActiveTakeRegions(
    List<ActiveTakePlaybackRegion> regions,
  ) async => const Ok(null);

  @override
  EpochId get currentEpoch => _epoch;

  @override
  Result<EpochId> flushAndAdvanceEpoch() {
    _epoch = EpochId(_epoch.value + 1);
    return Ok(_epoch);
  }

  MuseError? nextScheduleError;

  @override
  Result<int> scheduleEvents(
    List<ScheduledMidiEvent> events, {
    SampleFrame? scheduledUpToFrame,
  }) {
    if (nextScheduleError != null) {
      return Err(nextScheduleError!);
    }
    scheduledEvents.addAll(events);
    return Ok(events.length);
  }

  @override
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  }) => const Ok(null);

  @override
  Result<void> setChannelMix({
    required int midiChannel,
    required double gainDb,
    required double pan,
  }) => const Ok(null);

  @override
  Result<void> silenceChannel(int midiChannel) => const Ok(null);

  @override
  Result<void> triggerLiveAuditionNote({
    required int midiChannel,
    required int pitchMidi,
    required int velocity,
    required bool isNoteOn,
  }) => const Ok(null);

  @override
  Result<void> setMonitorGain(double gainLinear) => const Ok(null);

  @override
  Future<Result<void>> prepareAndStartCapture(TakeId takeId) async =>
      const Ok(null);

  @override
  Future<Result<RecordingCaptureReceipt>> stopAndFinalizeCapture(
    TakeId takeId,
  ) async => Ok(
    RecordingCaptureReceipt(
      takeId: takeId,
      stagingPath: '/staging/${takeId.value}.wav.part',
      sha256: Sha256Digest('f' * 64),
      capturedSampleClock: const SampleFrame(48000),
      capturedPlayheadFrame: const SampleFrame(0),
      durationFrames: 48000,
      sampleRate: 48000,
      channelCount: 1,
      outputBufferFrames: 256,
      inputBufferFrames: 128,
    ),
  );

  @override
  TelemetrySnapshot? get latestSnapshot => _latestSnapshot;

  @override
  List<TelemetrySnapshot> drainTelemetry({
    int maxFrames = MuseConstants.maxTelemetryDrainFrames,
  }) {
    if (queuedTelemetry.isEmpty) {
      return const <TelemetrySnapshot>[];
    }
    final count = queuedTelemetry.length > maxFrames
        ? maxFrames
        : queuedTelemetry.length;
    final out = queuedTelemetry.sublist(0, count);
    queuedTelemetry.removeRange(0, count);
    _latestSnapshot = out.last;
    return out;
  }
}

void main() {
  group('ProjectCatalogController (Task 6.1a)', () {
    late _FakeProjectRepository projectRepo;
    late _FakeAssetLibraryRepository assetRepo;
    late _FakeExternalFileExchange fileExchange;
    late _FakeStorageMaintenanceRepository storageMaintenance;
    late _FakeAudioBridge bridge;
    late _FakeAudioSessionController audioSession;
    late DualModelScoreService dualModel;
    late SoundFontPresetParser sfParser;
    late LookaheadPlaybackCoordinator playback;
    late RecordingSessionCoordinator recorder;

    ProjectId? activeProjectId;
    Set<SoundFontId> activeUsedSfIds = <SoundFontId>{};
    var detachCalls = 0;
    final reopenedIds = <ProjectId>[];
    Future<Result<void>> Function(ProjectId)? customReopenBehavior;
    var uuidSeq = 0;
    var clock = 10000;

    late ProjectCatalogController controller;

    setUp(() {
      uuidSeq = 0;
      clock = 10000;
      activeProjectId = null;
      activeUsedSfIds = <SoundFontId>{};
      detachCalls = 0;
      reopenedIds.clear();
      customReopenBehavior = null;

      projectRepo = _FakeProjectRepository();
      assetRepo = _FakeAssetLibraryRepository(
        linkedProjectRepository: projectRepo,
      );
      assetRepo.seedSoundFont(
        const SoundFontCatalogEntry(
          sfId: SoundFontId('sf-default'),
          name: 'Default GS',
          blobSha256: Sha256Digest(MuseConstants.defaultSoundFontSha256),
          byteSize: MuseConstants.defaultSoundFontByteSize,
          presets: <SoundFontPresetInfo>[
            SoundFontPresetInfo(
              bankNum: 0,
              programNum: 0,
              presetName: 'Acoustic Grand Piano',
            ),
          ],
          createdAtMs: 100,
          updatedAtMs: 100,
        ),
      );
      fileExchange = _FakeExternalFileExchange();
      storageMaintenance = _FakeStorageMaintenanceRepository();
      bridge = _FakeAudioBridge();
      audioSession = _FakeAudioSessionController();
      dualModel = DualModelScoreService();
      sfParser = SoundFontPresetParser();

      playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: bridge,
        transportBridge: bridge,
        synthEventBridge: bridge,
        telemetryBridge: bridge,
        assetLibraryRepository: assetRepo,
      );
      recorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storageMaintenance,
        assetLibrary: assetRepo,
        projectRepository: projectRepo,
        lifecycleBridge: bridge,
        transportBridge: bridge,
        synthEventBridge: bridge,
        recordingBridge: bridge,
        telemetryBridge: bridge,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => null,
        countInMeasures: 0,
      );

      controller = ProjectCatalogController(
        projectRepository: projectRepo,
        assetLibraryRepository: assetRepo,
        externalFileExchange: fileExchange,
        storageMaintenanceRepository: storageMaintenance,
        dualModelScoreService: dualModel,
        soundFontPresetParser: sfParser,
        playbackCoordinator: playback,
        recordingCoordinator: recorder,
        audioSessionController: audioSession,
        activeProjectIdProvider: () => activeProjectId,
        activeProjectSoundFontIdsProvider: () => activeUsedSfIds,
        detachActiveProjectHook: () async {
          detachCalls += 1;
          activeProjectId = null;
          activeUsedSfIds = <SoundFontId>{};
          await playback.detachProject();
          return const Ok(null);
        },
        reopenProjectHook: (projectId) async {
          reopenedIds.add(projectId);
          if (customReopenBehavior != null) {
            return customReopenBehavior!(projectId);
          }
          return const Ok(null);
        },
        uuidV7Generator: () {
          uuidSeq += 1;
          return '01950000-0000-7000-8000-${uuidSeq.toString().padLeft(12, '0')}';
        },
        nowEpochMs: () {
          clock += 1000;
          return clock;
        },
      );
    });

    tearDown(() async {
      controller.dispose();
      await playback.dispose();
      audioSession.dispose();
    });

    test(
      'paginated loadCatalogInitial & loadMoreProjects load slices without duplicates',
      () async {
        for (var i = 0; i < 30; i++) {
          final res = await projectRepo.createProject(
            CreateProjectInput(
              projectId: ProjectId('p-$i'),
              title: 'Score $i',
              gridSnapTicks: MuseConstants.sixteenthNoteTicks,
              initialUsPerQuarter: 500000,
              initialTimeSigNumerator: 4,
              initialTimeSigDenominator: 4,
            ),
          );
          expect(res.isOk, isTrue);
        }

        final initRes = await controller.loadCatalogInitial();
        expect(initRes.isOk, isTrue);
        expect(controller.state.projects.length, 25);
        expect(controller.state.hasMoreProjects, isTrue);
        expect(controller.state.nextOffset, 25);
        expect(controller.state.soundFonts.length, 1);

        final moreRes = await controller.loadMoreProjects();
        expect(moreRes.isOk, isTrue);
        expect(controller.state.projects.length, 30);
        expect(controller.state.hasMoreProjects, isFalse);
        expect(controller.state.nextOffset, 30);
      },
    );

    test(
      'createBlankProject updates seeded P1 part cleanly without orphan Part 1 or duplicate P1 collision',
      () async {
        await controller.loadCatalogInitial();
        final createdRes = await controller.createBlankProject(
          title: '  Piano Grand  ',
          initialSoundFontId: const SoundFontId('sf-default'),
          tempoBpm: 96,
          numerator: 3,
          denominator: 4,
          stavesCount: 2,
        );
        expect(createdRes, isA<Ok<ProjectSummary>>());
        final summary = (createdRes as Ok<ProjectSummary>).value;
        expect(summary.title, 'Piano Grand');
        expect(summary.revision, 1);

        final agg =
            (await projectRepo.loadProjectAggregate(summary.projectId)
                    as Ok<ProjectWorkspaceAggregate>)
                .value;
        expect(agg.parts.length, 1);
        expect(agg.parts.single.musicXmlPartId, 'P1');
        expect(agg.parts.single.name, MusePresentationConstants.defaultInitialPartName);
        expect(agg.parts.single.stavesCount, 2);
        expect(agg.parts.single.sfId, const SoundFontId('sf-default'));
        expect(agg.clefEvents.length, 2);
        expect(agg.clefEvents.map((c) => c.staffNumber).toSet(), {1, 2});
        expect(agg.tempoEvents.single.usPerQuarter, 625000);
        expect(agg.timeSignatureEvents.single.numerator, 3);
        expect(agg.timeSignatureEvents.single.denominator, 4);

        final invalidBlank = await controller.createBlankProject(
          title: '   ',
          initialSoundFontId: const SoundFontId('sf-default'),
        );
        expect(
          (invalidBlank as Err<ProjectSummary>).error.code,
          MuseErrorCode.sqliteConstraintViolation,
        );
      },
    );

    test(
      'importMusicXmlProject replaces seeded P1/clef/key rows cleanly and exportProjectToMusicXml exports .musicxml/.mxl',
      () async {
        await controller.loadCatalogInitial();

        const xml = '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE score-partwise PUBLIC "-//Recordare//DTD MusicXML 3.1 Partwise//EN" "http://www.musicxml.org/dtds/partwise.dtd">
<score-partwise version="3.1">
  <part-list>
    <score-part id="P1"><part-name>Flute</part-name></score-part>
  </part-list>
  <part id="P1">
    <measure number="1">
      <attributes>
        <divisions>2</divisions>
        <key><fifths>1</fifths><mode>major</mode></key>
        <time><beats>4</beats><beat-type>4</beat-type></time>
        <clef><sign>G</sign><line>2</line></clef>
      </attributes>
      <note>
        <pitch><step>G</step><octave>4</octave></pitch>
        <duration>2</duration>
        <voice>1</voice>
        <type>quarter</type>
      </note>
    </measure>
  </part>
</score-partwise>''';
        final xmlBytes = Uint8List.fromList(utf8.encode(xml));
        fileExchange.nextPickedFile = PickedExternalFile(
          fileName: 'Etude_One.musicxml',
          extension: 'musicxml',
          byteLength: xmlBytes.length,
          byteStream: Stream<List<int>>.value(xmlBytes),
        );

        final importRes = await controller.importMusicXmlProject();
        expect(importRes, isA<Ok<ProjectSummary?>>());
        final imported = (importRes as Ok<ProjectSummary?>).value!;
        expect(imported.title, 'Etude_One');

        final loadedAgg =
            (await projectRepo.loadProjectAggregate(imported.projectId)
                    as Ok<ProjectWorkspaceAggregate>)
                .value;
        expect(loadedAgg.parts.length, 1);
        expect(loadedAgg.parts.single.name, 'Flute');
        expect(loadedAgg.notes.length, 1);
        expect(loadedAgg.keySignatureEvents.single.fifths, 1);

        final exportXml = await controller.exportProjectToMusicXml(
          projectId: imported.projectId,
          compressAsMxl: false,
        );
        expect(exportXml.isOk, isTrue);
        expect(fileExchange.exportedFiles.last.suggestedFileName, 'Etude_One.musicxml');

        final exportMxl = await controller.exportProjectToMusicXml(
          projectId: imported.projectId,
          compressAsMxl: true,
        );
        expect(exportMxl.isOk, isTrue);
        expect(fileExchange.exportedFiles.last.suggestedFileName, 'Etude_One.mxl');

        // Re-import the exported compressed .mxl bytes cleanly.
        final mxlBytes = fileExchange.exportedFiles.last.bytes;
        fileExchange.nextPickedFile = PickedExternalFile(
          fileName: 'Roundtrip.mxl',
          extension: 'mxl',
          byteLength: mxlBytes.length,
          byteStream: Stream<List<int>>.value(mxlBytes),
        );
        final reimported = await controller.importMusicXmlProject();
        final reimportedSummary = (reimported as Ok<ProjectSummary?>).value!;
        expect(reimportedSummary.title, 'Etude_One');
        final reimportedAgg =
            (await projectRepo.loadProjectAggregate(reimportedSummary.projectId)
                    as Ok<ProjectWorkspaceAggregate>)
                .value;
        expect(reimportedAgg.parts.single.name, 'Flute');
        expect(reimportedAgg.notes.length, 1);
      },
    );

    test(
      'importSoundFontFile uses byteStreamFactory on Native, bounded replay when null, and rejects >64MiB on Web or low quota fail-closed',
      () async {
        await controller.loadCatalogInitial();
        final sf2 = _buildMinimalSf2();
        var streamFactoryInvocations = 0;

        // 1. Native replayable stream factory (O(1) RAM two-pass).
        fileExchange.nextPickedFile = PickedExternalFile(
          fileName: 'ConcertGrand.sf2',
          extension: 'sf2',
          byteLength: sf2.length,
          byteStream: Stream<List<int>>.fromIterable(<List<int>>[
            sf2.sublist(0, 16),
            sf2.sublist(16),
          ]),
          byteStreamFactory: () {
            streamFactoryInvocations += 1;
            return Stream<List<int>>.value(sf2);
          },
        );
        final nativeImport = await controller.importSoundFontFile();
        expect(nativeImport, isA<Ok<SoundFontCatalogEntry?>>());
        expect(streamFactoryInvocations, 1);
        expect(
          (nativeImport as Ok<SoundFontCatalogEntry?>).value!.presets.length,
          2,
        );

        // 2. Single-pass bounded chunk replay when byteStreamFactory == null.
        fileExchange.nextPickedFile = PickedExternalFile(
          fileName: 'WebSmall.sf2',
          extension: 'sf2',
          byteLength: sf2.length,
          byteStream: Stream<List<int>>.fromIterable(<List<int>>[
            sf2.sublist(0, 20),
            sf2.sublist(20),
          ]),
        );
        final smallReplay = await controller.importSoundFontFile();
        expect(smallReplay, isA<Ok<SoundFontCatalogEntry?>>());
        expect(controller.state.soundFonts.length, 3);

        // 3. Web > 64 MiB cap fails closed before reading stream.
        audioSession.currentPlatform = CalibrationPlatform.web;
        var streamReadOnOversizedWeb = false;
        fileExchange.nextPickedFile = PickedExternalFile(
          fileName: 'Huge.sf2',
          extension: 'sf2',
          byteLength: MuseConstants.maxWebSoundFontBytes + 1,
          byteStream: Stream<List<int>>.multi((sink) {
            streamReadOnOversizedWeb = true;
            sink.close();
          }),
        );
        final webTooLarge = await controller.importSoundFontFile();
        expect(
          (webTooLarge as Err<SoundFontCatalogEntry?>).error.code,
          MuseErrorCode.soundFontTooLargeForWeb,
        );
        expect(streamReadOnOversizedWeb, isFalse);

        // 4. Low quota fails closed before reading stream.
        audioSession.currentPlatform = CalibrationPlatform.macos;
        storageMaintenance.availableQuotaBytes = 8;
        fileExchange.nextPickedFile = PickedExternalFile(
          fileName: 'BlockedByQuota.sf2',
          extension: 'sf2',
          byteLength: sf2.length,
          byteStream: Stream<List<int>>.value(sf2),
        );
        final quotaErr = await controller.importSoundFontFile();
        expect(
          (quotaErr as Err<SoundFontCatalogEntry?>).error.code,
          MuseErrorCode.insufficientStorageQuota,
        );
      },
    );

    test(
      'deleteSoundFont detaches active referencing workspace, unloads non-active SF, invokes reopenProjectHook & surfaces missingSoundFontForPart',
      () async {
        await controller.loadCatalogInitial();
        final unusedEntry = SoundFontCatalogEntry(
          sfId: const SoundFontId('sf-unused'),
          name: 'Unused SF',
          blobSha256: Sha256Digest('b' * 64),
          byteSize: 1024,
          presets: const <SoundFontPresetInfo>[
            SoundFontPresetInfo(bankNum: 0, programNum: 0, presetName: 'Pad'),
          ],
          createdAtMs: 200,
          updatedAtMs: 200,
        );
        assetRepo.seedSoundFont(unusedEntry);

        final blankRes = await controller.createBlankProject(
          title: 'Active SF Project',
          initialSoundFontId: const SoundFontId('sf-default'),
        );
        final project = (blankRes as Ok<ProjectSummary>).value;
        final initialAgg =
            (await projectRepo.loadProjectAggregate(project.projectId)
                    as Ok<ProjectWorkspaceAggregate>)
                .value;
        await projectRepo.commitScoreMutationBatch(
          ScoreMutationBatch(
            projectId: project.projectId,
            expectedRevision: project.revision,
            upsertNotes: <TimelineNote>[
              TimelineNote(
                noteId: const NoteId('n-sf-check'),
                projectId: project.projectId,
                partId: initialAgg.parts.single.partId,
                staffNumber: 1,
                voiceNumber: 1,
                pitchMidi: 60,
                enharmonicStep: EnharmonicStep.C,
                enharmonicAlter: 0,
                rawStartTick: const Tick(0),
                rawDurationTicks: MuseConstants.quarterNoteTicks,
                quantizedStartTick: const Tick(0),
                quantizedDurationTicks: MuseConstants.quarterNoteTicks,
                velocity: 96,
                updatedAtMs: 1000,
              ),
            ],
          ),
        );
        final agg =
            (await projectRepo.loadProjectAggregate(project.projectId)
                    as Ok<ProjectWorkspaceAggregate>)
                .value;
        final ws = (dualModel.buildWorkspaceState(agg) as Ok<ScoreWorkspaceState>)
            .value;
        await playback.attachProject(ws);
        activeProjectId = project.projectId;
        activeUsedSfIds = const <SoundFontId>{SoundFontId('sf-default')};

        // Delete non-active SoundFont: does NOT detach active project.
        final delUnused = await controller.deleteSoundFont(
          const SoundFontId('sf-unused'),
        );
        expect(delUnused.isOk, isTrue);
        expect(detachCalls, 0);
        expect(reopenedIds, isEmpty);

        // Delete active SoundFont: detaches active project, runs GC, nulls sf_id, reopens & surfaces missingSoundFontForPart.
        customReopenBehavior = (pid) async {
          final reloadedAgg =
              (await projectRepo.loadProjectAggregate(pid)
                      as Ok<ProjectWorkspaceAggregate>)
                  .value;
          final reloadedWs =
              (dualModel.buildWorkspaceState(reloadedAgg)
                      as Ok<ScoreWorkspaceState>)
                  .value;
          return playback.attachProject(reloadedWs);
        };
        final delActive = await controller.deleteSoundFont(
          const SoundFontId('sf-default'),
        );
        expect(detachCalls, 1);
        expect(reopenedIds, <ProjectId>[project.projectId]);
        expect(storageMaintenance.gcCutoffs, isNotEmpty);
        expect(
          (delActive as Err<void>).error.code,
          MuseErrorCode.missingSoundFontForPart,
        );
        expect(
          controller.state.soundFonts.any(
            (s) => s.sfId == const SoundFontId('sf-default'),
          ),
          isFalse,
        );
      },
    );

    test(
      'calibration guards unattached hardware, validates sample-rate-derived offset bounds, saves & realigns takes',
      () async {
        // 1. Unattached hardware fails closed without throwing StateError.
        audioSession.audioSessionStatus.value = const AudioSessionStatus(
          phase: AudioSessionPhase.requiresWebUserGesture,
        );
        final unattachedLoad = await controller
            .loadCalibrationProfileForCurrentHardware();
        expect(
          (unattachedLoad as Err<LatencyCalibrationProfile?>).error.code,
          MuseErrorCode.audioDeviceInitFailed,
        );

        // 2. Ready hardware at 44100 Hz clamps to ±44100 frames (±1000 ms).
        const hw44k = AudioHardwareInfo(
          sampleRate: 44100,
          inputChannels: 1,
          outputChannels: 2,
          inputBufferFrames: 128,
          outputBufferFrames: 256,
          deviceFingerprint: 'usb-44k',
        );
        bridge.hardwareInfo = hw44k;
        audioSession.audioSessionStatus.value = const AudioSessionStatus(
          phase: AudioSessionPhase.ready,
          hardwareInfo: hw44k,
        );

        final blank =
            (await controller.createBlankProject(
                      title: 'Cal Test',
                      initialSoundFontId: const SoundFontId('sf-default'),
                    )
                    as Ok<ProjectSummary>)
                .value;
        final agg =
            (await projectRepo.loadProjectAggregate(blank.projectId)
                    as Ok<ProjectWorkspaceAggregate>)
                .value;
        await projectRepo.promoteAndCommitRecordedTake(
          receipt: RecordingCaptureReceipt(
            takeId: const TakeId('take-cal-1'),
            stagingPath: '/staging/take-cal-1.wav.part',
            sha256: Sha256Digest('d' * 64),
            capturedSampleClock: const SampleFrame(44100),
            capturedPlayheadFrame: const SampleFrame(44100),
            durationFrames: 44100,
            sampleRate: 44100,
            channelCount: 1,
            outputBufferFrames: 256,
            inputBufferFrames: 128,
          ),
          projectId: blank.projectId,
          partId: agg.parts.single.partId,
          alignedStartTick: const Tick(1920),
          calibrationOffsetFrames: 0,
        );

        final outOfRange = await controller.saveCalibrationProfileAndRealign(
          calibrationOffsetFrames: 44101,
          targetProjectId: blank.projectId,
        );
        expect(
          (outOfRange as Err<LatencyCalibrationProfile>).error.code,
          MuseErrorCode.invalidTickRange,
        );

        final saved = await controller.saveCalibrationProfileAndRealign(
          calibrationOffsetFrames: -512,
          targetProjectId: blank.projectId,
        );
        expect(saved.isOk, isTrue);
        final loaded = await controller.loadCalibrationProfileForCurrentHardware();
        expect(
          (loaded as Ok<LatencyCalibrationProfile?>)
              .value
              ?.calibrationOffsetFrames,
          -512,
        );
        final realignedAgg =
            (await projectRepo.loadProjectAggregate(blank.projectId)
                    as Ok<ProjectWorkspaceAggregate>)
                .value;
        expect(realignedAgg.audioTakes.single.calibrationOffsetFrames, -512);

        // 3. Rename, export WAV take, purge take, delete project & run manual GC.
        expect(
          (await controller.renameProjectInCatalog(
            project: blank,
            newTitle: 'Calibrated Take Project',
          ))
              .isOk,
          isTrue,
        );
        expect(
          (await controller.exportRecordedTakeToWav(
            take: realignedAgg.audioTakes.single,
            partName: 'Piano',
          ))
              .isOk,
          isTrue,
        );
        expect(fileExchange.exportedWavTakes.single.suggestedFileName, 'Piano_take-cal-1.wav');

        activeProjectId = blank.projectId;
        expect(
          (await controller.purgePartAudioTakeInCatalog(
            projectId: blank.projectId,
            partId: agg.parts.single.partId,
          ))
              .isOk,
          isTrue,
        );
        expect(detachCalls, 1);

        activeProjectId = blank.projectId;
        expect((await controller.deleteProject(blank.projectId)).isOk, isTrue);
        expect(detachCalls, 2);

        final gcRes = await controller.reclaimUnusedStorageNow();
        expect((gcRes as Ok<int>).value, 3);
      },
    );
  });

  group('WorkspaceShellController (Task 6.1b)', () {
    late _FakeProjectRepository projectRepo;
    late _FakeAssetLibraryRepository assetRepo;
    late _FakeAudioBridge bridge;
    late _FakeAudioSessionController audioSession;
    late DualModelScoreService dualModel;
    late LookaheadPlaybackCoordinator playback;
    late WorkspaceShellController shell;
    var uuidSeq = 0;
    var clock = 20000;

    setUp(() async {
      uuidSeq = 0;
      clock = 20000;
      projectRepo = _FakeProjectRepository();
      assetRepo = _FakeAssetLibraryRepository(
        linkedProjectRepository: projectRepo,
      );
      assetRepo.seedSoundFont(
        const SoundFontCatalogEntry(
          sfId: SoundFontId('sf-default'),
          name: 'Default GS',
          blobSha256: Sha256Digest(MuseConstants.defaultSoundFontSha256),
          byteSize: MuseConstants.defaultSoundFontByteSize,
          presets: <SoundFontPresetInfo>[
            SoundFontPresetInfo(
              bankNum: 0,
              programNum: 0,
              presetName: 'Acoustic Grand Piano',
            ),
          ],
          createdAtMs: 100,
          updatedAtMs: 100,
        ),
      );
      bridge = _FakeAudioBridge();
      audioSession = _FakeAudioSessionController();
      dualModel = DualModelScoreService();
      playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: bridge,
        transportBridge: bridge,
        synthEventBridge: bridge,
        telemetryBridge: bridge,
        assetLibraryRepository: assetRepo,
        workspaceStateProvider: () => shell.currentWorkspace,
      );
      shell = WorkspaceShellController(
        projectRepository: projectRepo,
        dualModelScoreService: dualModel,
        playbackCoordinator: playback,
        audioSessionController: audioSession,
        uuidV7Generator: () {
          uuidSeq += 1;
          return '01960000-0000-7000-8000-${uuidSeq.toString().padLeft(12, '0')}';
        },
        nowEpochMs: () {
          clock += 1000;
          return clock;
        },
      );
    });

    tearDown(() async {
      await shell.closeProject();
      shell.dispose();
      await playback.dispose();
      audioSession.dispose();
    });

    Future<ProjectId> seedSinglePartProject({
      required String id,
      SoundFontId? sfId = const SoundFontId('sf-default'),
      bool withNote = false,
    }) async {
      final pid = ProjectId(id);
      final created = (await projectRepo.createProject(
        CreateProjectInput(
          projectId: pid,
          title: 'Workspace Score',
          gridSnapTicks: MuseConstants.sixteenthNoteTicks,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      ) as Ok<ProjectSummary>)
          .value;
      final agg = (await projectRepo.loadProjectAggregate(pid)
              as Ok<ProjectWorkspaceAggregate>)
          .value;
      final p1 = agg.parts.single;
      await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: pid,
          expectedRevision: created.revision,
          upsertParts: <ProjectPartEntity>[
            ProjectPartEntity(
              partId: p1.partId,
              projectId: pid,
              musicXmlPartId: p1.musicXmlPartId,
              sortOrder: p1.sortOrder,
              name: 'Piano',
              stavesCount: 1,
              midiChannel: 0,
              sfId: sfId,
              bankNum: 0,
              programNum: 0,
              gainDb: 0.0,
              pan: 0.0,
              isMuted: false,
              isSolo: false,
              updatedAtMs: 1000,
            ),
          ],
          upsertNotes: withNote
              ? <TimelineNote>[
                  TimelineNote(
                    noteId: NoteId('note-$id'),
                    projectId: pid,
                    partId: p1.partId,
                    staffNumber: 1,
                    voiceNumber: 1,
                    pitchMidi: 60,
                    enharmonicStep: EnharmonicStep.C,
                    enharmonicAlter: 0,
                    rawStartTick: const Tick(0),
                    rawDurationTicks: MuseConstants.quarterNoteTicks,
                    quantizedStartTick: const Tick(0),
                    quantizedDurationTicks: MuseConstants.quarterNoteTicks,
                    velocity: 96,
                    updatedAtMs: 1000,
                  ),
                ]
              : const <TimelineNote>[],
        ),
      );
      return pid;
    }

    test(
      'openProject, closeProject disposes IScoreEditingCommandBus & detaches playback',
      () async {
        final pid = await seedSinglePartProject(id: 'proj-open-close');
        var disposeCount = 0;
        IScoreEditingCommandBus? createdBus;

        final customShell = WorkspaceShellController(
          projectRepository: projectRepo,
          dualModelScoreService: dualModel,
          playbackCoordinator: playback,
          audioSessionController: audioSession,
          commandBusFactory: ({
            required initialState,
            required projectRepository,
            required dualModelService,
            required playbackCoordinator,
          }) {
            final real = ScoreEditingCommandBus(
              initialState: initialState,
              projectRepository: projectRepository,
              dualModelService: dualModelService,
              playbackCoordinator: playbackCoordinator,
            );
            createdBus = _DisposeCountingCommandBus(
              real,
              onDispose: () => disposeCount += 1,
            );
            return createdBus!;
          },
        );

        final openRes = await customShell.openProject(pid);
        expect(openRes.isOk, isTrue);
        expect(customShell.currentWorkspace, isNotNull);
        expect(playback.attachedWorkspace, isNotNull);
        expect(
          customShell.activeUsedSoundFontIds,
          const <SoundFontId>{SoundFontId('sf-default')},
        );

        await customShell.closeProject();
        expect(disposeCount, 1);
        expect(customShell.currentWorkspace, isNull);
        expect(customShell.state.commandBus, isNull);
        expect(playback.attachedWorkspace, isNull);
        customShell.dispose();
      },
    );

    test(
      'addPart chooses lowest unused P_n after deletion, skips GM Ch 9 for melodic parts, and dispatches Undo/Redo',
      () async {
        final pid = await seedSinglePartProject(id: 'proj-parts');
        expect((await shell.openProject(pid)).isOk, isTrue);

        // Add P2 (ch 1) and P3 (drums -> ch 9).
        final addP2 = await shell.addPart(
          name: 'Violin',
          stavesCount: 1,
          sfId: const SoundFontId('sf-default'),
          bankNum: 0,
          programNum: 40,
          initialClefSign: ClefSign.G,
          initialClefLine: 2,
        );
        expect(addP2.isOk, isTrue);
        final p2 = shell.currentWorkspace!.aggregate.parts.firstWhere(
          (p) => p.name == 'Violin',
        );
        expect(p2.musicXmlPartId, 'P2');
        expect(p2.midiChannel, 1);

        final addPerc = await shell.addPart(
          name: 'Drums',
          stavesCount: 1,
          sfId: const SoundFontId('sf-default'),
          bankNum: 128,
          programNum: 0,
          initialClefSign: ClefSign.percussion,
          initialClefLine: 2,
          isPercussion: true,
        );
        expect(addPerc.isOk, isTrue);
        final drums = shell.currentWorkspace!.aggregate.parts.firstWhere(
          (p) => p.name == 'Drums',
        );
        expect(drums.musicXmlPartId, 'P3');
        expect(drums.midiChannel, MuseConstants.gmPercussionChannel);

        // Remove P2, then add another part -> must reuse P2 and channel 1!
        expect((await shell.removePart(p2.partId)).isOk, isTrue);
        final addReused = await shell.addPart(
          name: 'Cello',
          stavesCount: 1,
          sfId: const SoundFontId('sf-default'),
          bankNum: 0,
          programNum: 42,
          initialClefSign: ClefSign.F,
          initialClefLine: 4,
        );
        expect(addReused.isOk, isTrue);
        final cello = shell.currentWorkspace!.aggregate.parts.firstWhere(
          (p) => p.name == 'Cello',
        );
        expect(cello.musicXmlPartId, 'P2');
        expect(cello.midiChannel, 1);

        // Update mixer, reorder, settings, tempo, and verify Undo/Redo.
        expect(
          (await shell.updatePartMixerOrPatch(
            ProjectPartEntity(
              partId: cello.partId,
              projectId: cello.projectId,
              musicXmlPartId: cello.musicXmlPartId,
              sortOrder: cello.sortOrder,
              name: cello.name,
              stavesCount: cello.stavesCount,
              midiChannel: cello.midiChannel,
              sfId: cello.sfId,
              bankNum: cello.bankNum,
              programNum: cello.programNum,
              gainDb: -3.5,
              pan: 0.25,
              isMuted: true,
              isSolo: false,
              updatedAtMs: clock + 1,
            ),
          ))
              .isOk,
          isTrue,
        );
        final orderedIds = shell.currentWorkspace!.aggregate.parts
            .map((p) => p.partId)
            .toList()
            .reversed
            .toList();
        expect((await shell.reorderParts(orderedIds)).isOk, isTrue);
        expect(
          shell.currentWorkspace!.aggregate.parts.map((p) => p.partId).toList(),
          orderedIds,
        );
        final restoredIds = orderedIds.reversed.toList();
        expect((await shell.reorderParts(restoredIds)).isOk, isTrue);
        expect(
          shell.currentWorkspace!.aggregate.parts.map((p) => p.partId).toList(),
          restoredIds,
        );

        expect(
          (await shell.updateProjectSettings(
            title: 'Edited Title',
            gridSnapTicks: MuseConstants.eighthNoteTicks,
            playbackTimingMode: PlaybackTimingMode.raw,
          ))
              .isOk,
          isTrue,
        );
        expect(shell.currentWorkspace!.aggregate.project.title, 'Edited Title');
        expect(shell.state.canUndo, isTrue);

        expect((await shell.undo()).isOk, isTrue);
        expect(
          shell.currentWorkspace!.aggregate.project.title,
          'Workspace Score',
        );
        expect(shell.state.canRedo, isTrue);

        expect((await shell.redo()).isOk, isTrue);
        expect(shell.currentWorkspace!.aggregate.project.title, 'Edited Title');

        expect((await shell.clearPartAudio(cello.partId)).isOk, isTrue);
        expect(shell.buildTimelineCalculatorForActiveWorkspace(), isNotNull);
      },
    );

    test(
      'reloadProjectById keeps workspace open on missingSoundFontForPart and reattaches once SoundFont is reassigned; Web requires gesture attach',
      () async {
        final pid = await seedSinglePartProject(
          id: 'proj-missing-sf',
          sfId: null,
          withNote: true,
        );
        final reloadRes = await shell.reloadProjectById(pid);
        expect(
          (reloadRes as Err<void>).error.code,
          MuseErrorCode.missingSoundFontForPart,
        );
        // Kept open in edit-inspect mode!
        expect(shell.currentWorkspace, isNotNull);
        expect(
          shell.state.lastError?.code,
          MuseErrorCode.missingSoundFontForPart,
        );
        expect(playback.attachedWorkspace, isNull);

        // Assign replacement SoundFont via updatePartMixerOrPatch -> auto-reattaches!
        final p1 = shell.currentWorkspace!.aggregate.parts.single;
        final patchRes = await shell.updatePartMixerOrPatch(
          ProjectPartEntity(
            partId: p1.partId,
            projectId: p1.projectId,
            musicXmlPartId: p1.musicXmlPartId,
            sortOrder: p1.sortOrder,
            name: p1.name,
            stavesCount: p1.stavesCount,
            midiChannel: p1.midiChannel,
            sfId: const SoundFontId('sf-default'),
            bankNum: 0,
            programNum: 0,
            gainDb: 0.0,
            pan: 0.0,
            isMuted: false,
            isSolo: false,
            updatedAtMs: 9999,
          ),
        );
        expect(patchRes.isOk, isTrue);
        expect(shell.state.lastError, isNull);
        expect(playback.attachedWorkspace, isNotNull);

        // Web unattached open followed by user gesture ensureAudioInitializedAndAttach().
        await shell.closeProject();
        audioSession.currentPlatform = CalibrationPlatform.web;
        audioSession.audioSessionStatus.value = const AudioSessionStatus(
          phase: AudioSessionPhase.requiresWebUserGesture,
        );
        final webOpen = await shell.openProject(pid);
        expect(webOpen.isOk, isTrue);
        expect(shell.currentWorkspace, isNotNull);
        expect(playback.attachedWorkspace, isNull);

        final gestureAttach = await shell.ensureAudioInitializedAndAttach();
        expect(gestureAttach.isOk, isTrue);
        expect(audioSession.initializeCalls, 1);
        expect(playback.attachedWorkspace, isNotNull);
      },
    );
  });

  group('TransportAndTelemetryController (Task 6.1c)', () {
    late _FakeProjectRepository projectRepo;
    late _FakeAssetLibraryRepository assetRepo;
    late _FakeStorageMaintenanceRepository storageMaintenance;
    late _FakeAudioBridge bridge;
    late _FakeAudioSessionController audioSession;
    late DualModelScoreService dualModel;
    late LookaheadPlaybackCoordinator playback;
    late WorkspaceShellController shell;
    late _SpyRecordingCoordinator spyRecorder;
    late _ManualTestTicker ticker;
    late TransportAndTelemetryController transport;

    setUp(() async {
      projectRepo = _FakeProjectRepository();
      assetRepo = _FakeAssetLibraryRepository(
        linkedProjectRepository: projectRepo,
      );
      assetRepo.seedSoundFont(
        const SoundFontCatalogEntry(
          sfId: SoundFontId('sf-default'),
          name: 'Default GS',
          blobSha256: Sha256Digest(MuseConstants.defaultSoundFontSha256),
          byteSize: MuseConstants.defaultSoundFontByteSize,
          presets: <SoundFontPresetInfo>[
            SoundFontPresetInfo(
              bankNum: 0,
              programNum: 0,
              presetName: 'Acoustic Grand Piano',
            ),
          ],
          createdAtMs: 100,
          updatedAtMs: 100,
        ),
      );
      storageMaintenance = _FakeStorageMaintenanceRepository();
      bridge = _FakeAudioBridge();
      audioSession = _FakeAudioSessionController();
      dualModel = DualModelScoreService();
      playback = LookaheadPlaybackCoordinator(
        lifecycleBridge: bridge,
        transportBridge: bridge,
        synthEventBridge: bridge,
        telemetryBridge: bridge,
        assetLibraryRepository: assetRepo,
        workspaceStateProvider: () => shell.currentWorkspace,
      );
      shell = WorkspaceShellController(
        projectRepository: projectRepo,
        dualModelScoreService: dualModel,
        playbackCoordinator: playback,
        audioSessionController: audioSession,
      );

      final realRecorder = RecordingSessionCoordinator(
        currentPlatform: CalibrationPlatform.macos,
        storageMaintenance: storageMaintenance,
        assetLibrary: assetRepo,
        projectRepository: projectRepo,
        lifecycleBridge: bridge,
        transportBridge: bridge,
        synthEventBridge: bridge,
        recordingBridge: bridge,
        telemetryBridge: bridge,
        playbackCoordinator: playback,
        activeWorkspaceProvider: () => shell.currentWorkspace,
        countInMeasures: 1,
        countInDelay: (_) async {},
      );
      spyRecorder = _SpyRecordingCoordinator(realRecorder);

      // Seed a multi-tempo project: tick 0 = 120 BPM (500_000 us/q), tick 960 = 60 BPM (1_000_000 us/q).
      const pid = ProjectId('proj-telemetry');
      final created = (await projectRepo.createProject(
        const CreateProjectInput(
          projectId: pid,
          title: 'Multi-Tempo Telemetry',
          gridSnapTicks: MuseConstants.sixteenthNoteTicks,
          initialUsPerQuarter: 500000,
          initialTimeSigNumerator: 4,
          initialTimeSigDenominator: 4,
        ),
      ) as Ok<ProjectSummary>)
          .value;
      final agg = (await projectRepo.loadProjectAggregate(pid)
              as Ok<ProjectWorkspaceAggregate>)
          .value;
      final p1 = agg.parts.single;
      await projectRepo.commitScoreMutationBatch(
        ScoreMutationBatch(
          projectId: pid,
          expectedRevision: created.revision,
          upsertParts: <ProjectPartEntity>[
            ProjectPartEntity(
              partId: p1.partId,
              projectId: pid,
              musicXmlPartId: p1.musicXmlPartId,
              sortOrder: p1.sortOrder,
              name: 'Piano',
              stavesCount: 1,
              midiChannel: 0,
              sfId: const SoundFontId('sf-default'),
              bankNum: 0,
              programNum: 0,
              gainDb: 0.0,
              pan: 0.0,
              isMuted: false,
              isSolo: false,
              updatedAtMs: 1000,
            ),
          ],
          upsertTempoEvents: const <TempoEventEntity>[
            TempoEventEntity(
              tempoEventId: TempoEventId('tempo-60'),
              projectId: pid,
              tick: Tick(960),
              usPerQuarter: 1000000,
              updatedAtMs: 1000,
            ),
          ],
        ),
      );
      expect((await shell.openProject(pid)).isOk, isTrue);

      transport = TransportAndTelemetryController(
        playbackCoordinator: playback,
        recordingCoordinator: spyRecorder,
        synthEventBridge: bridge,
        telemetryBridge: bridge,
        audioSessionController: audioSession,
        workspaceShellController: shell,
        tickerFactory: (onTick) {
          ticker = _ManualTestTicker(onTick);
          return ticker;
        },
      );
    });

    tearDown(() async {
      transport.dispose();
      await shell.closeProject();
      shell.dispose();
      await playback.dispose();
      audioSession.dispose();
    });

    test(
      '60Hz Ticker drains telemetry, filters stale epoch packets, tracks multi-tempo playheadTick, and guards unattached hardware',
      () {
        var tickNotifications = 0;
        var meterNotifications = 0;
        transport.playheadTick.addListener(() => tickNotifications += 1);
        transport.meters.addListener(() => meterNotifications += 1);

        // Empty drain performs zero notifications.
        ticker.fire(const Duration(milliseconds: 17));
        expect(tickNotifications, 0);
        expect(meterNotifications, 0);

        // Unattached/errored audio session guards hardwareInfo without throwing StateError.
        audioSession.audioSessionStatus.value = const AudioSessionStatus(
          phase: AudioSessionPhase.failed,
        );
        bridge.queuedTelemetry.add(
          TelemetrySnapshot(
            playheadSampleFrame: const SampleFrame(48000),
            activeEpoch: bridge.currentEpoch,
            outputPeakL: 0.5,
            outputPeakR: 0.5,
            outputRmsL: 0.3,
            outputRmsR: 0.3,
            inputPeak: 0.1,
            inputRms: 0.05,
            isPlaying: true,
            isCapturing: false,
            hasEventQueueUnderrun: false,
            hasCaptureBufferOverflow: false,
            hasTakePlaybackUnderrun: false,
          ),
        );
        ticker.fire(const Duration(milliseconds: 34));
        expect(bridge.queuedTelemetry.length, 1); // Did not drain while unready.

        // Ready session: stale epoch snapshot is ignored for playhead, valid epoch converts across 120->60 BPM!
        // At 48000 Hz: beat 1 (tick 0..960 @ 120 BPM) = 24000 frames; beat 2 (tick 960..1920 @ 60 BPM) = 48000 frames -> total 72000 frames = tick 1920.
        audioSession.audioSessionStatus.value = AudioSessionStatus(
          phase: AudioSessionPhase.ready,
          hardwareInfo: bridge.hardwareInfo,
        );
        final staleEpoch = EpochId(bridge.currentEpoch.value - 1);
        bridge.queuedTelemetry.clear();
        bridge.queuedTelemetry.addAll(<TelemetrySnapshot>[
          TelemetrySnapshot(
            playheadSampleFrame: const SampleFrame(72000),
            activeEpoch: bridge.currentEpoch,
            outputPeakL: 0.4,
            outputPeakR: 0.6,
            outputRmsL: 0.2,
            outputRmsR: 0.3,
            inputPeak: 0.15,
            inputRms: 0.05,
            isPlaying: true,
            isCapturing: false,
            hasEventQueueUnderrun: false,
            hasCaptureBufferOverflow: false,
            hasTakePlaybackUnderrun: false,
          ),
          TelemetrySnapshot(
            playheadSampleFrame: const SampleFrame(999999),
            activeEpoch: staleEpoch,
            outputPeakL: 0.8,
            outputPeakR: 0.2,
            outputRmsL: 0.2,
            outputRmsR: 0.2,
            inputPeak: 0.1,
            inputRms: 0.05,
            isPlaying: true,
            isCapturing: false,
            hasEventQueueUnderrun: false,
            hasCaptureBufferOverflow: false,
            hasTakePlaybackUnderrun: false,
          ),
        ]);
        ticker.fire(const Duration(milliseconds: 51));
        expect(transport.playheadTick.value, const Tick(1920));
        expect(transport.meters.value.outputPeakL, 0.8);
        expect(transport.meters.value.outputPeakR, 0.6);
      },
    );

    test(
      'caps circular liveRecordingWaveform at TelemetryConstants.maxWaveformSamples and aborts capture single-flight on captureBufferOverflow',
      () async {
        final partId = shell.currentWorkspace!.aggregate.parts.single.partId;
        transport.togglePartArmForRecording(partId);
        expect(transport.armedPartId, partId);

        transport.setCountInEnabled(false);
        final recRes = await transport.startRecordingOnArmedPart(
          punchInTick: const Tick(0),
        );
        expect(recRes.isOk, isTrue);
        expect(spyRecorder.startCalls.single.countInOverride, 0);
        expect(transport.isRecording, isTrue);

        // Push > TelemetryConstants.maxWaveformSamples (1800) in batches of 128.
        const totalSamples = TelemetryConstants.maxWaveformSamples + 250;
        for (var i = 0; i < totalSamples; i++) {
          bridge.queuedTelemetry.add(
            TelemetrySnapshot(
              playheadSampleFrame: SampleFrame(i * 100),
              activeEpoch: bridge.currentEpoch,
              outputPeakL: 0.1,
              outputPeakR: 0.1,
              outputRmsL: 0.05,
              outputRmsR: 0.05,
              inputPeak: (i % 100) / 100.0,
              inputRms: 0.2,
              isPlaying: true,
              isCapturing: true,
              hasEventQueueUnderrun: false,
              hasCaptureBufferOverflow: false,
              hasTakePlaybackUnderrun: false,
            ),
          );
        }
        var elapsedMs = 20;
        while (bridge.queuedTelemetry.isNotEmpty) {
          ticker.fire(Duration(milliseconds: elapsedMs));
          elapsedMs += 20;
        }
        expect(
          transport.liveRecordingWaveform.value.length,
          TelemetryConstants.maxWaveformSamples,
        );

        // Hold stopAndCommitRecording async to prove single-flight _overflowTerminationInFlight latch!
        final holdStop = Completer<Result<AudioTakeEntity>>();
        spyRecorder.holdNextStopCompleter = holdStop;

        bridge.queuedTelemetry.addAll(<TelemetrySnapshot>[
          TelemetrySnapshot(
            playheadSampleFrame: const SampleFrame(1000),
            activeEpoch: bridge.currentEpoch,
            outputPeakL: 0.1,
            outputPeakR: 0.1,
            outputRmsL: 0.05,
            outputRmsR: 0.05,
            inputPeak: 0.1,
            inputRms: 0.05,
            isPlaying: true,
            isCapturing: true,
            hasEventQueueUnderrun: false,
            hasCaptureBufferOverflow: true, // Intermediate overflow!
            hasTakePlaybackUnderrun: false,
          ),
          TelemetrySnapshot(
            playheadSampleFrame: const SampleFrame(1200),
            activeEpoch: bridge.currentEpoch,
            outputPeakL: 0.1,
            outputPeakR: 0.1,
            outputRmsL: 0.05,
            outputRmsR: 0.05,
            inputPeak: 0.1,
            inputRms: 0.05,
            isPlaying: true,
            isCapturing: true,
            hasEventQueueUnderrun: false,
            hasCaptureBufferOverflow: false,
            hasTakePlaybackUnderrun: false,
          ),
        ]);
        ticker.fire(Duration(milliseconds: elapsedMs));
        expect(
          transport.activeAlert?.code,
          MuseErrorCode.captureBufferOverflow,
        );
        expect(spyRecorder.stopCalls, 1);

        // A second tick with overflow while termination is in-flight must NOT re-enter stopAndCommitRecording.
        bridge.queuedTelemetry.add(
          TelemetrySnapshot(
            playheadSampleFrame: const SampleFrame(1400),
            activeEpoch: bridge.currentEpoch,
            outputPeakL: 0.1,
            outputPeakR: 0.1,
            outputRmsL: 0.05,
            outputRmsR: 0.05,
            inputPeak: 0.1,
            inputRms: 0.05,
            isPlaying: true,
            isCapturing: true,
            hasEventQueueUnderrun: false,
            hasCaptureBufferOverflow: true,
            hasTakePlaybackUnderrun: false,
          ),
        );
        ticker.fire(Duration(milliseconds: elapsedMs + 20));
        expect(spyRecorder.stopCalls, 1);

        holdStop.complete(
          const Err(
            MuseError(
              MuseErrorCode.captureBufferOverflow,
              'Overflow aborted cleanly.',
            ),
          ),
        );
        await Future<void>.delayed(Duration.zero);
        expect(transport.isRecording, isFalse);
      },
    );

    test(
      'surfaces underrun flags, play/pause/stop/seek/loop/monitorGain, and dismissTelemetryAlert',
      () async {
        // Underrun telemetry alerts.
        bridge.queuedTelemetry.add(
          TelemetrySnapshot(
            playheadSampleFrame: const SampleFrame(0),
            activeEpoch: bridge.currentEpoch,
            outputPeakL: 0.0,
            outputPeakR: 0.0,
            outputRmsL: 0.0,
            outputRmsR: 0.0,
            inputPeak: 0.0,
            inputRms: 0.0,
            isPlaying: false,
            isCapturing: false,
            hasEventQueueUnderrun: true,
            hasCaptureBufferOverflow: false,
            hasTakePlaybackUnderrun: false,
          ),
        );
        ticker.fire(const Duration(milliseconds: 20));
        expect(transport.activeAlert?.code, MuseErrorCode.eventQueueUnderrun);
        transport.dismissTelemetryAlert();
        expect(transport.activeAlert, isNull);

        bridge.queuedTelemetry.add(
          TelemetrySnapshot(
            playheadSampleFrame: const SampleFrame(0),
            activeEpoch: bridge.currentEpoch,
            outputPeakL: 0.0,
            outputPeakR: 0.0,
            outputRmsL: 0.0,
            outputRmsR: 0.0,
            inputPeak: 0.0,
            inputRms: 0.0,
            isPlaying: false,
            isCapturing: false,
            hasEventQueueUnderrun: false,
            hasCaptureBufferOverflow: false,
            hasTakePlaybackUnderrun: true,
          ),
        );
        ticker.fire(const Duration(milliseconds: 40));
        expect(
          transport.activeAlert?.code,
          MuseErrorCode.takePlaybackBufferUnderrun,
        );
        transport.dismissTelemetryAlert();

        // Transport, seek, loop & monitor gain validation.
        expect((await transport.play()).isOk, isTrue);
        expect(transport.isPlaying, isTrue);
        expect(transport.pause().isOk, isTrue);
        expect(transport.isPlaying, isFalse);

        expect(transport.seekToTick(const Tick(960)).isOk, isTrue);
        expect(transport.playheadTick.value, const Tick(960));

        expect(
          transport
              .setLoopTickRange(
                enabled: true,
                startTick: const Tick(0),
                endTick: const Tick(1920),
              )
              .isOk,
          isTrue,
        );
        expect(transport.isLoopEnabled, isTrue);
        expect(transport.loopTickRange?.endTick, const Tick(1920));

        expect(transport.stop().isOk, isTrue);
        expect(transport.playheadTick.value, const Tick(0));

        expect(transport.setMonitorGain(0.5).isOk, isTrue);
        expect(transport.monitorGainLinear, 0.5);
        expect(
          (transport.setMonitorGain(1.5) as Err<void>).error.code,
          MuseErrorCode.invalidTickRange,
        );
        transport.dismissTelemetryAlert();

        // Verify playbackCoordinator.asyncErrors propagates into activeAlert.
        final p1 = shell.currentWorkspace!.aggregate.parts.single;
        expect((await transport.play()).isOk, isTrue);
        bridge.nextScheduleError = const MuseError(
          MuseErrorCode.eventQueueOverflow,
          'Simulated async refill overflow.',
        );
        await shell.executeScoreCommand(
          InsertNotesCommand(<TimelineNote>[
            TimelineNote(
              noteId: const NoteId('async-err-note'),
              projectId: shell.currentWorkspace!.aggregate.project.projectId,
              partId: p1.partId,
              staffNumber: 1,
              voiceNumber: 1,
              pitchMidi: 64,
              enharmonicStep: EnharmonicStep.E,
              enharmonicAlter: 0,
              rawStartTick: const Tick(0),
              rawDurationTicks: MuseConstants.quarterNoteTicks,
              quantizedStartTick: const Tick(0),
              quantizedDurationTicks: MuseConstants.quarterNoteTicks,
              velocity: 96,
              updatedAtMs: 5000,
            ),
          ]),
        );
        await Future<void>.delayed(Duration.zero);
        expect(
          transport.activeAlert?.code,
          MuseErrorCode.eventQueueOverflow,
        );
        bridge.nextScheduleError = null;
        transport.stop();
      },
    );

    test(
      'queues pre-attach loop until play/attach and preserves playhead tick & loop frames on BPM edits',
      () async {
        final pid = shell.currentWorkspace!.aggregate.project.projectId;
        await shell.closeProject();

        // Simulate Web pre-gesture state before reopening project.
        audioSession.audioSessionStatus.value = const AudioSessionStatus(
          phase: AudioSessionPhase.requiresWebUserGesture,
        );
        expect((await shell.openProject(pid)).isOk, isTrue);
        expect(playback.isAttached, isFalse);

        // Toggle loop BEFORE audio attach -> queued cleanly in L5 without error.
        expect(
          transport
              .setLoopTickRange(
                enabled: true,
                startTick: const Tick(0),
                endTick: const Tick(15360),
              )
              .isOk,
          isTrue,
        );
        expect(transport.isLoopEnabled, isTrue);
        expect(
          transport.loopTickRange,
          (startTick: const Tick(0), endTick: const Tick(15360)),
        );

        // Pressing Play initializes audio, attaches project, and applies Bar 1-4 loop to engine!
        // Multi-tempo seed: 0..960 @ 120 BPM (24000) + 960..15360 @ 60 BPM (720000) = 744000 frames.
        expect((await transport.play()).isOk, isTrue);
        expect(playback.isAttached, isTrue);
        expect(playback.isLoopEnabled, isTrue);
        expect(bridge.lastLoopRegion?.enabled, isTrue);
        expect(bridge.lastLoopRegion?.end, const SampleFrame(744000));

        // Pause at Bar 3 (7680 ticks = 24000 + 7*48000 = 360000 frames), then change Tick-0 BPM to 60.
        expect(transport.pause().isOk, isTrue);
        expect(transport.seekToTick(const Tick(7680)).isOk, isTrue);
        expect(transport.playheadSampleFrame.value, const SampleFrame(360000));

        final tick0Tempo = shell.currentWorkspace!.aggregate.tempoEvents.first;
        expect(
          (await shell.executeScoreCommand(
            UpsertTempoEventCommand(
              TempoEventEntity(
                tempoEventId: tick0Tempo.tempoEventId,
                projectId: pid,
                tick: const Tick(0),
                usPerQuarter: 1000000, // 60 BPM
                updatedAtMs: 9000,
              ),
            ),
          )).isOk,
          isTrue,
        );
        await Future<void>.delayed(Duration.zero);

        // Playhead stays locked at Bar 3 (7680 ticks), sample frame re-anchors 360000 -> 384000,
        // and engine loop region expands from 744000 to 768000 frames!
        expect(transport.playheadTick.value, const Tick(7680));
        expect(transport.playheadSampleFrame.value, const SampleFrame(384000));
        expect(bridge.lastLoopRegion?.end, const SampleFrame(768000));
      },
    );
  });
}

final class _DisposeCountingCommandBus implements IScoreEditingCommandBus {
  final ScoreEditingCommandBus _inner;
  final void Function() onDispose;

  _DisposeCountingCommandBus(this._inner, {required this.onDispose});

  @override
  ScoreWorkspaceState get currentState => _inner.currentState;

  @override
  Stream<ScoreWorkspaceState> get stateStream => _inner.stateStream;

  @override
  bool get canUndo => _inner.canUndo;

  @override
  bool get canRedo => _inner.canRedo;

  @override
  Future<Result<ScoreWorkspaceState>> execute(ScoreCommand command) =>
      _inner.execute(command);

  @override
  Future<Result<ScoreWorkspaceState>> undo() => _inner.undo();

  @override
  Future<Result<ScoreWorkspaceState>> redo() => _inner.redo();

  @override
  Future<T> runSerialized<T>(Future<T> Function() action) =>
      _inner.runSerialized(action);

  @override
  Future<void> syncCommittedTake(AudioTakeEntity take) =>
      _inner.syncCommittedTake(take);

  @override
  Future<void> syncRealignedTakes(List<AudioTakeEntity> takes) =>
      _inner.syncRealignedTakes(takes);

  @override
  Future<void> dispose() async {
    onDispose();
    await _inner.dispose();
  }
}

final class _ManualTestTicker extends Ticker {
  final TickerCallback _callback;
  bool isStarted = false;
  bool isDisposed = false;

  _ManualTestTicker(this._callback) : super(_callback);

  void fire(Duration elapsed) {
    if (isStarted && !isDisposed) {
      _callback(elapsed);
    }
  }

  @override
  TickerFuture start() {
    isStarted = true;
    return TickerFuture.complete();
  }

  @override
  void stop({bool canceled = false}) {
    isStarted = false;
  }

  @override
  void dispose() {
    isStarted = false;
    isDisposed = true;
    super.dispose();
  }
}

final class _SpyRecordingCoordinator implements IRecordingSessionCoordinator {
  final IRecordingSessionCoordinator _inner;
  final List<({PartId partId, Tick startTick, int? countInOverride})>
  startCalls =
      <({PartId partId, Tick startTick, int? countInOverride})>[];
  int stopCalls = 0;
  Completer<Result<AudioTakeEntity>>? holdNextStopCompleter;

  _SpyRecordingCoordinator(this._inner);

  @override
  Result<void> setInputMonitorGain(double gainLinear) =>
      _inner.setInputMonitorGain(gainLinear);

  @override
  Future<Result<TakeId>> startRecordingOnPart({
    required PartId partId,
    required Tick countInStartTick,
    int? countInMeasuresOverride,
  }) {
    startCalls.add((
      partId: partId,
      startTick: countInStartTick,
      countInOverride: countInMeasuresOverride,
    ));
    return _inner.startRecordingOnPart(
      partId: partId,
      countInStartTick: countInStartTick,
      countInMeasuresOverride: countInMeasuresOverride,
    );
  }

  @override
  Future<Result<AudioTakeEntity>> stopAndCommitRecording() {
    stopCalls += 1;
    final held = holdNextStopCompleter;
    if (held != null) {
      holdNextStopCompleter = null;
      return held.future;
    }
    return _inner.stopAndCommitRecording();
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignProjectTakesForCalibration({
    required ProjectId projectId,
    required int newCalibrationOffsetFrames,
  }) => _inner.realignProjectTakesForCalibration(
    projectId: projectId,
    newCalibrationOffsetFrames: newCalibrationOffsetFrames,
  );
}
