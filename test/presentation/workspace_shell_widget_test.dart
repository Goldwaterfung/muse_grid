import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crisp_notation/crisp_notation.dart'
    show MusicFont, MusicFonts, StaffSystemView;
import 'package:flutter/scheduler.dart' show Ticker, TickerCallback, TickerFuture;
import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
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
import 'package:muse_grid/presentation/notation/staff_notation_view_controller.dart';
import 'package:muse_grid/presentation/piano_roll/piano_roll_viewport_controller.dart';
import 'package:muse_grid/presentation/workspace/muse_grid_workspace_screen.dart';
import 'package:muse_grid/presentation/workspace/soundfont_and_calibration_dialogs.dart';

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
    SoundFontPresetInfo(bankNum: 0, programNum: 40, presetName: 'Violin'),
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

final class _ManualTicker extends Ticker {
  final TickerCallback _callback;

  _ManualTicker(this._callback) : super(_callback);

  @override
  TickerFuture start() => TickerFuture.complete();

  @override
  void stop({bool canceled = false}) {}

  void trigger(Duration elapsed) => _callback(elapsed);
}

final class _FakeAudioSession implements IAudioSessionController {
  @override
  CalibrationPlatform currentPlatform = CalibrationPlatform.macos;

  @override
  final ValueNotifier<AudioSessionStatus> audioSessionStatus = ValueNotifier(
    const AudioSessionStatus(
      phase: AudioSessionPhase.ready,
      hardwareInfo: AudioHardwareInfo(
        sampleRate: 48000,
        inputChannels: 1,
        outputChannels: 2,
        inputBufferFrames: 256,
        outputBufferFrames: 256,
        deviceFingerprint: 'mac-test-device',
      ),
    ),
  );

  int ensureInitCalls = 0;

  @override
  Future<Result<AudioHardwareInfo>> ensureAudioInitialized() async {
    ensureInitCalls += 1;
    final hw = audioSessionStatus.value.hardwareInfo ??
        const AudioHardwareInfo(
          sampleRate: 48000,
          inputChannels: 1,
          outputChannels: 2,
          inputBufferFrames: 256,
          outputBufferFrames: 256,
          deviceFingerprint: 'mac-test-device',
        );
    audioSessionStatus.value = AudioSessionStatus(
      phase: AudioSessionPhase.ready,
      hardwareInfo: hw,
    );
    return Ok(hw);
  }

  void dispose() => audioSessionStatus.dispose();
}

final class _FakeStorageMaintenance implements IStorageMaintenanceRepository {
  int availableQuotaBytes = 256 * MuseConstants.bytesPerMib;
  int gcReclaimedReturn = 3;
  int gcCalls = 0;

  @override
  Future<Result<void>> initializeAndVerifyStorage() async => const Ok(null);

  @override
  Future<Result<int>> verifyAvailableQuotaBytes({
    required int requiredBytes,
  }) async {
    if (availableQuotaBytes < requiredBytes) {
      return const Err(
        MuseError(MuseErrorCode.insufficientStorageQuota, 'Low disk space'),
      );
    }
    return Ok(availableQuotaBytes);
  }

  @override
  Future<Result<int>> runGarbageCollection({
    required int olderThanEpochMs,
  }) async {
    gcCalls += 1;
    return Ok(gcReclaimedReturn);
  }

  @override
  Future<void> close() async {}
}

final class _FakeProjectRepo implements IProjectRepository {
  final Map<ProjectId, ProjectWorkspaceAggregate> _projects =
      <ProjectId, ProjectWorkspaceAggregate>{};
  int _clock = 1000;
  int deletedTakesCount = 0;

  void seedAggregate(ProjectWorkspaceAggregate aggregate) {
    _projects[aggregate.project.projectId] = aggregate;
  }

  @override
  Future<Result<List<ProjectSummary>>> listActiveProjects({
    required int limit,
    required int offset,
  }) async {
    final all = _projects.values.map((e) => e.project).toList(growable: false);
    if (offset >= all.length) {
      return const Ok(<ProjectSummary>[]);
    }
    final end = (offset + limit) > all.length ? all.length : (offset + limit);
    return Ok(all.sublist(offset, end));
  }

  @override
  Future<Result<ProjectWorkspaceAggregate>> loadProjectAggregate(
    ProjectId projectId,
  ) async {
    final agg = _projects[projectId];
    if (agg == null) {
      return const Err(
        MuseError(MuseErrorCode.entityNotFound, 'Project not found'),
      );
    }
    return Ok(agg);
  }

  @override
  Future<Result<ProjectSummary>> createProject(CreateProjectInput input) async {
    _clock += 10;
    final summary = ProjectSummary(
      projectId: input.projectId,
      title: input.title,
      ppqn: MuseConstants.ppqn,
      gridSnapTicks: input.gridSnapTicks,
      pickupTicks: input.pickupTicks,
      playbackTimingMode: input.playbackTimingMode,
      revision: 1,
      createdAtMs: _clock,
      updatedAtMs: _clock,
    );
    final partId = PartId('part-${input.projectId.value}-1');
    _projects[input.projectId] = ProjectWorkspaceAggregate(
      project: summary,
      parts: <ProjectPartEntity>[
        ProjectPartEntity(
          partId: partId,
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
          tempoEventId: TempoEventId('t0-${input.projectId.value}'),
          projectId: input.projectId,
          tick: const Tick(0),
          usPerQuarter: input.initialUsPerQuarter,
          updatedAtMs: _clock,
        ),
      ],
      timeSignatureEvents: <TimeSignatureEventEntity>[
        TimeSignatureEventEntity(
          tsEventId: TimeSigEventId('ts0-${input.projectId.value}'),
          projectId: input.projectId,
          tick: const Tick(0),
          numerator: input.initialTimeSigNumerator,
          denominator: input.initialTimeSigDenominator,
          updatedAtMs: _clock,
        ),
      ],
      keySignatureEvents: const <KeySignatureEventEntity>[],
      clefEvents: <ClefEventEntity>[
        ClefEventEntity(
          clefEventId: ClefEventId('c0-${input.projectId.value}'),
          projectId: input.projectId,
          partId: partId,
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
    final existing = _projects[input.projectId];
    if (existing == null) {
      return const Err(MuseError(MuseErrorCode.entityNotFound, 'Missing'));
    }
    _clock += 10;
    final p = existing.project;
    _projects[input.projectId] = ProjectWorkspaceAggregate(
      project: ProjectSummary(
        projectId: p.projectId,
        title: input.title ?? p.title,
        ppqn: p.ppqn,
        gridSnapTicks: input.gridSnapTicks ?? p.gridSnapTicks,
        pickupTicks: input.pickupTicks ?? p.pickupTicks,
        playbackTimingMode: input.playbackTimingMode ?? p.playbackTimingMode,
        revision: p.revision + 1,
        createdAtMs: p.createdAtMs,
        updatedAtMs: _clock,
      ),
      parts: existing.parts,
      tempoEvents: existing.tempoEvents,
      timeSignatureEvents: existing.timeSignatureEvents,
      keySignatureEvents: existing.keySignatureEvents,
      clefEvents: existing.clefEvents,
      notes: existing.notes,
      spanners: existing.spanners,
      audioTakes: existing.audioTakes,
    );
    return const Ok(null);
  }

  @override
  Future<Result<void>> softDeleteProject(
    ProjectId projectId, {
    required int deletedAtMs,
  }) async {
    _projects.remove(projectId);
    return const Ok(null);
  }

  @override
  Future<Result<int>> commitScoreMutationBatch(ScoreMutationBatch batch) async {
    final current = _projects[batch.projectId];
    if (current == null) {
      return const Err(MuseError(MuseErrorCode.entityNotFound, 'Missing'));
    }
    _clock += 10;
    final nextRev = current.project.revision + 1;
    final meta = batch.projectMetadataUpdate;
    final project = ProjectSummary(
      projectId: current.project.projectId,
      title: meta?.title ?? current.project.title,
      ppqn: current.project.ppqn,
      gridSnapTicks: meta?.gridSnapTicks ?? current.project.gridSnapTicks,
      pickupTicks: meta?.pickupTicks ?? current.project.pickupTicks,
      playbackTimingMode:
          meta?.playbackTimingMode ?? current.project.playbackTimingMode,
      revision: nextRev,
      createdAtMs: current.project.createdAtMs,
      updatedAtMs: _clock,
    );

    final parts = <PartId, ProjectPartEntity>{
      for (final p in current.parts) p.partId: p,
    };
    for (final id in batch.deletePartIds) {
      parts.remove(id);
    }
    for (final p in batch.upsertParts) {
      parts[p.partId] = p;
    }

    final tempos = <TempoEventId, TempoEventEntity>{
      for (final t in current.tempoEvents) t.tempoEventId: t,
    };
    for (final id in batch.deleteTempoEventIds) {
      tempos.remove(id);
    }
    for (final t in batch.upsertTempoEvents) {
      tempos[t.tempoEventId] = t;
    }

    final timeSigs = <TimeSigEventId, TimeSignatureEventEntity>{
      for (final ts in current.timeSignatureEvents) ts.tsEventId: ts,
    };
    for (final id in batch.deleteTimeSignatureEventIds) {
      timeSigs.remove(id);
    }
    for (final ts in batch.upsertTimeSignatureEvents) {
      timeSigs[ts.tsEventId] = ts;
    }

    final keySigs = <KeySigEventId, KeySignatureEventEntity>{
      for (final ks in current.keySignatureEvents) ks.keyEventId: ks,
    };
    for (final id in batch.deleteKeySignatureEventIds) {
      keySigs.remove(id);
    }
    for (final ks in batch.upsertKeySignatureEvents) {
      keySigs[ks.keyEventId] = ks;
    }

    final clefs = <ClefEventId, ClefEventEntity>{
      for (final c in current.clefEvents) c.clefEventId: c,
    };
    for (final id in batch.deleteClefEventIds) {
      clefs.remove(id);
    }
    for (final c in batch.upsertClefEvents) {
      clefs[c.clefEventId] = c;
    }

    final notes = <NoteId, TimelineNote>{
      for (final n in current.notes) n.noteId: n,
    };
    for (final id in batch.deleteNoteIds) {
      notes.remove(id);
    }
    for (final n in batch.upsertNotes) {
      notes[n.noteId] = n;
    }

    final spanners = <SpannerId, NoteSpannerEntity>{
      for (final s in current.spanners) s.spannerId: s,
    };
    for (final id in batch.deleteSpannerIds) {
      spanners.remove(id);
    }
    for (final s in batch.upsertSpanners) {
      spanners[s.spannerId] = s;
    }

    final takes = List<AudioTakeEntity>.from(current.audioTakes)
      ..removeWhere((t) => batch.deleteAudioTakePartIds.contains(t.partId));
    for (final upsertTake in batch.upsertAudioTakes) {
      takes.removeWhere((t) => t.partId == upsertTake.partId);
      takes.add(upsertTake);
    }

    _projects[batch.projectId] = ProjectWorkspaceAggregate(
      project: project,
      parts: parts.values.toList(growable: false)
        ..sort((a, b) => a.sortOrder.compareTo(b.sortOrder)),
      tempoEvents: tempos.values.toList(growable: false),
      timeSignatureEvents: timeSigs.values.toList(growable: false),
      keySignatureEvents: keySigs.values.toList(growable: false),
      clefEvents: clefs.values.toList(growable: false),
      notes: notes.values.toList(growable: false),
      spanners: spanners.values.toList(growable: false),
      audioTakes: takes,
    );
    return Ok(nextRev);
  }

  @override
  Future<Result<AudioTakeEntity>> promoteAndCommitRecordedTake({
    required RecordingCaptureReceipt receipt,
    required ProjectId projectId,
    required PartId partId,
    required Tick alignedStartTick,
    required int calibrationOffsetFrames,
  }) async {
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
    return Ok(take);
  }

  @override
  Future<Result<List<AudioTakeEntity>>> realignAudioTakesCalibration({
    required ProjectId projectId,
    required List<AudioTakeRealignmentUpdate> updates,
  }) async {
    final agg = _projects[projectId];
    if (agg == null) {
      return const Ok(<AudioTakeEntity>[]);
    }
    final byId = {for (final u in updates) u.takeId: u};
    final updated = agg.audioTakes
        .map<AudioTakeEntity>((t) {
          final u = byId[t.takeId];
          if (u == null) {
            return t;
          }
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
        })
        .toList(growable: false);
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
    deletedTakesCount += 1;
    final agg = _projects[projectId];
    if (agg != null) {
      _projects[projectId] = ProjectWorkspaceAggregate(
        project: agg.project,
        parts: agg.parts,
        tempoEvents: agg.tempoEvents,
        timeSignatureEvents: agg.timeSignatureEvents,
        keySignatureEvents: agg.keySignatureEvents,
        clefEvents: agg.clefEvents,
        notes: agg.notes,
        spanners: agg.spanners,
        audioTakes: agg.audioTakes
            .where((t) => t.partId != partId)
            .toList(growable: false),
      );
    }
    return const Ok(null);
  }

  /// Mirrors SQLite `ON DELETE SET NULL` on `parts.sf_id`.
  void clearSoundFontReferences(SoundFontId sfId) {
    for (final entry in _projects.entries.toList()) {
      final agg = entry.value;
      var changed = false;
      final nextParts = agg.parts
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
          parts: nextParts,
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
}

final class _FakeAssetRepo implements IAssetLibraryRepository {
  final List<SoundFontCatalogEntry> entries = <SoundFontCatalogEntry>[];
  LatencyCalibrationProfile? savedCalibration;
  void Function(SoundFontId sfId)? onSoftDelete;
  int sfSeq = 0;

  void seedDefaultSf() {
    entries.add(
      const SoundFontCatalogEntry(
        sfId: SoundFontId('sf-default'),
        name: 'GeneralUser GS',
        blobSha256: Sha256Digest(MuseConstants.defaultSoundFontSha256),
        byteSize: MuseConstants.defaultSoundFontByteSize,
        presets: <SoundFontPresetInfo>[
          SoundFontPresetInfo(
            bankNum: 0,
            programNum: 0,
            presetName: 'Grand Piano',
          ),
          SoundFontPresetInfo(
            bankNum: 0,
            programNum: 48,
            presetName: 'Strings',
          ),
        ],
        createdAtMs: 100,
        updatedAtMs: 100,
      ),
    );
  }

  @override
  Future<Result<List<SoundFontCatalogEntry>>> listActiveSoundFonts() async =>
      Ok(List<SoundFontCatalogEntry>.unmodifiable(entries));

  @override
  Future<Result<SoundFontCatalogEntry>> importSoundFontBytes({
    required String displayName,
    required Stream<List<int>> byteStream,
    required int byteLength,
    required List<SoundFontPresetInfo> extractedPresets,
  }) async {
    await byteStream.drain<void>();
    sfSeq += 1;
    final created = SoundFontCatalogEntry(
      sfId: SoundFontId('sf-imported-$sfSeq'),
      name: displayName,
      blobSha256: Sha256Digest('a' * 64),
      byteSize: byteLength,
      presets: extractedPresets,
      createdAtMs: 200,
      updatedAtMs: 200,
    );
    entries.add(created);
    return Ok(created);
  }

  @override
  Future<Result<void>> softDeleteSoundFont(
    SoundFontId sfId, {
    required int deletedAtMs,
  }) async {
    entries.removeWhere((e) => e.sfId == sfId);
    onSoftDelete?.call(sfId);
    return const Ok(null);
  }

  @override
  Future<Result<LatencyCalibrationProfile?>> getCalibrationProfile({
    required CalibrationPlatform platform,
    required String deviceFingerprint,
    required int sampleRate,
    required int bufferSizeFrames,
  }) async => Ok(savedCalibration);

  @override
  Future<Result<LatencyCalibrationProfile>> upsertCalibrationProfile(
    UpsertCalibrationProfileInput input,
  ) async {
    final profile = LatencyCalibrationProfile(
      profileId: const CalibrationProfileId('cal-1'),
      platform: input.platform,
      deviceFingerprint: input.deviceFingerprint,
      sampleRate: input.sampleRate,
      bufferSizeFrames: input.bufferSizeFrames,
      calibrationOffsetFrames: input.calibrationOffsetFrames,
      updatedAtMs: 500,
    );
    savedCalibration = profile;
    return Ok(profile);
  }
}

final class _FakeFileExchange implements IExternalFileExchange {
  PickedExternalFile? nextPick;
  final List<String> exportedFiles = <String>[];
  final List<String> exportedWavs = <String>[];

  @override
  Future<Result<PickedExternalFile?>> pickImportFile({
    required List<String> allowedExtensions,
  }) async => Ok(nextPick);

  @override
  Future<Result<void>> exportFileToUser({
    required String suggestedFileName,
    required String mimeType,
    required List<int> bytes,
  }) async {
    exportedFiles.add(suggestedFileName);
    return const Ok(null);
  }

  @override
  Future<Result<void>> exportCasWavTakeToUser({
    required Sha256Digest wavSha256,
    required String suggestedFileName,
  }) async {
    exportedWavs.add(suggestedFileName);
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
  @override
  AudioHardwareInfo currentHardwareInfo = const AudioHardwareInfo(
    sampleRate: 48000,
    inputChannels: 1,
    outputChannels: 2,
    inputBufferFrames: 256,
    outputBufferFrames: 256,
    deviceFingerprint: 'mac-test-device',
  );

  @override
  EpochId currentEpoch = const EpochId(1);

  final List<TelemetrySnapshot> queuedTelemetry = <TelemetrySnapshot>[];
  TelemetrySnapshot? _latestSnapshot;
  final List<({int channel, SoundFontHandle sf, int bank, int prog})> patches =
      <({int channel, SoundFontHandle sf, int bank, int prog})>[];
  final List<ScheduledMidiEvent> scheduledEvents = <ScheduledMidiEvent>[];
  double lastMonitorGain = 0.0;
  int _sfSeq = 0;

  @override
  TelemetrySnapshot? get latestSnapshot => _latestSnapshot;

  @override
  Future<Result<AudioHardwareInfo>> initialize() async =>
      Ok(currentHardwareInfo);

  @override
  Future<Result<LoadedSoundFontDescriptor>> loadSoundFontFromCas({
    required Sha256Digest sha256,
  }) async {
    _sfSeq += 1;
    return Ok(
      LoadedSoundFontDescriptor(
        handle: SoundFontHandle(_sfSeq),
        presets: const <SoundFontPresetInfo>[
          SoundFontPresetInfo(
            bankNum: 0,
            programNum: 0,
            presetName: 'Grand Piano',
          ),
        ],
      ),
    );
  }

  @override
  Future<Result<void>> unloadSoundFont(SoundFontHandle handle) async =>
      const Ok(null);

  @override
  Result<void> play() => const Ok(null);

  @override
  Result<void> pause() => const Ok(null);

  @override
  Result<void> stop() => const Ok(null);

  @override
  Result<EpochId> seekToSample(SampleFrame targetFrame) {
    currentEpoch = EpochId(currentEpoch.value + 1);
    return Ok(currentEpoch);
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
  Result<EpochId> flushAndAdvanceEpoch() {
    currentEpoch = EpochId(currentEpoch.value + 1);
    return Ok(currentEpoch);
  }

  @override
  Result<int> scheduleEvents(
    List<ScheduledMidiEvent> events, {
    SampleFrame? scheduledUpToFrame,
  }) {
    scheduledEvents.addAll(events);
    return Ok(events.length);
  }

  @override
  Result<void> assignChannelPatch({
    required int midiChannel,
    required SoundFontHandle sfHandle,
    required int bankNum,
    required int programNum,
  }) {
    patches.add((
      channel: midiChannel,
      sf: sfHandle,
      bank: bankNum,
      prog: programNum,
    ));
    return const Ok(null);
  }

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
  }) {
    scheduledEvents.add(
      ScheduledMidiEvent(
        epoch: currentEpoch,
        targetSampleFrame: const SampleFrame(MuseConstants.immediateDispatchFrame),
        type: isNoteOn ? MuseConstants.midiEventNoteOn : MuseConstants.midiEventNoteOff,
        channel: midiChannel,
        data1: pitchMidi,
        data2: velocity,
      ),
    );
    return const Ok(null);
  }

  @override
  Result<void> setMonitorGain(double gainLinear) {
    lastMonitorGain = gainLinear;
    return const Ok(null);
  }

  @override
  Future<Result<void>> prepareAndStartCapture(TakeId takeId) async =>
      const Ok(null);

  @override
  Future<Result<RecordingCaptureReceipt>> stopAndFinalizeCapture(
    TakeId takeId,
  ) async => Ok(
    RecordingCaptureReceipt(
      takeId: takeId,
      stagingPath: '/tmp/${takeId.value}.wav.part',
      sha256: Sha256Digest('b' * 64),
      capturedSampleClock: const SampleFrame(0),
      capturedPlayheadFrame: const SampleFrame(0),
      durationFrames: 48000,
      sampleRate: 48000,
      channelCount: 1,
      outputBufferFrames: 256,
      inputBufferFrames: 256,
    ),
  );

  @override
  List<TelemetrySnapshot> drainTelemetry({int maxFrames = 128}) {
    final copy = List<TelemetrySnapshot>.from(queuedTelemetry);
    queuedTelemetry.clear();
    if (copy.isNotEmpty) {
      _latestSnapshot = copy.last;
    }
    return copy;
  }

  @override
  Future<void> dispose() async {}
}

final class _ShellHarness {
  final _FakeAudioSession audioSession = _FakeAudioSession();
  final _FakeStorageMaintenance storage = _FakeStorageMaintenance();
  final _FakeProjectRepo projectRepo = _FakeProjectRepo();
  final _FakeAssetRepo assetRepo = _FakeAssetRepo();
  final _FakeFileExchange fileExchange = _FakeFileExchange();
  final _FakeAudioBridge bridge = _FakeAudioBridge();
  final DualModelScoreService dualModel = DualModelScoreService();
  late final LookaheadPlaybackCoordinator playback;
  late final RecordingSessionCoordinator recording;
  late final WorkspaceShellController workspaceController;
  late final ProjectCatalogController catalogController;
  late final TransportAndTelemetryController transportController;
  late final StaffNotationViewController notationController;
  late final PianoRollViewportController pianoRollController;
  _ManualTicker? manualTicker;
  int _uuidSeq = 0;

  _ShellHarness() {
    assetRepo.seedDefaultSf();
    assetRepo.onSoftDelete = projectRepo.clearSoundFontReferences;
    playback = LookaheadPlaybackCoordinator(
      lifecycleBridge: bridge,
      transportBridge: bridge,
      synthEventBridge: bridge,
      telemetryBridge: bridge,
      assetLibraryRepository: assetRepo,
      workspaceStateProvider: () => workspaceController.currentWorkspace,
      periodicTimerFactory: (_, _) => Timer(const Duration(days: 1), () {}),
    );
    recording = RecordingSessionCoordinator(
      currentPlatform: CalibrationPlatform.macos,
      storageMaintenance: storage,
      assetLibrary: assetRepo,
      projectRepository: projectRepo,
      lifecycleBridge: bridge,
      transportBridge: bridge,
      synthEventBridge: bridge,
      recordingBridge: bridge,
      telemetryBridge: bridge,
      playbackCoordinator: playback,
      activeWorkspaceProvider: () => workspaceController.currentWorkspace,
      onTakeCommitted: (t) => workspaceController.syncCommittedTake(t),
      onTakesRealigned: (ts) => workspaceController.syncRealignedTakes(ts),
      serializedProjectWrite: <T>(a) =>
          workspaceController.runSerializedIfActive<T>(a),
    );
    workspaceController = WorkspaceShellController(
      projectRepository: projectRepo,
      dualModelScoreService: dualModel,
      playbackCoordinator: playback,
      audioSessionController: audioSession,
      uuidV7Generator: () => 'id-${++_uuidSeq}',
      nowEpochMs: () => 5000 + _uuidSeq,
    );
    catalogController = ProjectCatalogController(
      projectRepository: projectRepo,
      assetLibraryRepository: assetRepo,
      externalFileExchange: fileExchange,
      storageMaintenanceRepository: storage,
      dualModelScoreService: dualModel,
      soundFontPresetParser: const SoundFontPresetParser(),
      playbackCoordinator: playback,
      recordingCoordinator: recording,
      audioSessionController: audioSession,
      activeProjectIdProvider: () =>
          workspaceController.currentWorkspace?.aggregate.project.projectId,
      activeProjectSoundFontIdsProvider: () =>
          workspaceController.activeUsedSoundFontIds,
      detachActiveProjectHook: () async {
        await workspaceController.closeProject();
        return const Ok(null);
      },
      reopenProjectHook: (pid) => workspaceController.reloadProjectById(pid),
      uuidV7Generator: () => 'id-${++_uuidSeq}',
      nowEpochMs: () => 5000 + _uuidSeq,
    );
    notationController = StaffNotationViewController(
      workspaceShellController: workspaceController,
      playbackCoordinator: playback,
      uuidV7Generator: () => 'id-${++_uuidSeq}',
      nowEpochMs: () => 5000 + _uuidSeq,
      auditionReleaseDelay: (_) async {},
    );
    pianoRollController = PianoRollViewportController(
      workspaceShellController: workspaceController,
      dualModelScoreService: dualModel,
      playbackCoordinator: playback,
      uuidV7Generator: () => 'id-${++_uuidSeq}',
      nowEpochMs: () => 5000 + _uuidSeq,
    );
    transportController = TransportAndTelemetryController(
      playbackCoordinator: playback,
      recordingCoordinator: recording,
      synthEventBridge: bridge,
      telemetryBridge: bridge,
      audioSessionController: audioSession,
      workspaceShellController: workspaceController,
      tickerFactory: (cb) {
        final t = _ManualTicker(cb);
        manualTicker = t;
        return t;
      },
    );
  }

  Widget buildApp() => MaterialApp(
    home: MuseGridWorkspaceScreen(
      catalogController: catalogController,
      workspaceController: workspaceController,
      transportController: transportController,
      staffNotationController: notationController,
      pianoRollController: pianoRollController,
      audioSessionController: audioSession,
    ),
  );

  Future<void> dispose() async {
    transportController.dispose();
    pianoRollController.dispose();
    notationController.dispose();
    catalogController.dispose();
    workspaceController.dispose();
    await playback.dispose();
    audioSession.dispose();
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    await MusicFonts.load(MusicFont.bravura);
  });

  testWidgets('ProjectCatalogView pagination, new project, rename, GC & delete', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = _ShellHarness();
    addTearDown(harness.dispose);

    // Seed 26 projects so pagination ("Load More Projects") appears at limit 25.
    for (var i = 0; i < 26; i++) {
      await harness.catalogController.createBlankProject(
        title: 'Seeded Project $i',
        initialSoundFontId: const SoundFontId('sf-default'),
      );
    }
    await harness.catalogController.loadCatalogInitial();

    await tester.pumpWidget(harness.buildApp());
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('project_catalog_view')), findsOneWidget);
    expect(find.text('Seeded Project 0'), findsOneWidget);
    expect(find.text('Seeded Project 25'), findsNothing);

    await tester.scrollUntilVisible(
      find.byKey(const Key('catalog_load_more_button')),
      300,
      scrollable: find.byType(Scrollable).last,
    );
    await tester.tap(find.byKey(const Key('catalog_load_more_button')));
    await tester.pumpAndSettle();
    expect(find.text('Seeded Project 25'), findsOneWidget);

    // Clean up cache calls GC cleanly.
    await tester.tap(find.byKey(const Key('catalog_gc_button')));
    await tester.pumpAndSettle();
    expect(harness.storage.gcCalls, 1);

    // Create Blank Project dialog creates project and transitions to workspace.
    await tester.tap(find.byKey(const Key('catalog_new_project_button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('new_project_title_field')),
      'Quartet Draft',
    );
    await tester.tap(find.byKey(const Key('new_project_confirm_button')));
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('project_catalog_view')), findsNothing);
    expect(
      harness.workspaceController.currentWorkspace?.aggregate.project.title,
      'Quartet Draft',
    );

    // Back to Catalog button returns cleanly.
    await tester.tap(find.byKey(const Key('transport_back_to_catalog')));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('project_catalog_view')), findsOneWidget);
  });

  testWidgets('SoundFontLibraryDialog enforces Web 64 MiB limit and deletion recovery', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = _ShellHarness();
    addTearDown(harness.dispose);
    await harness.catalogController.loadCatalogInitial();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () => unawaited(
                showSoundFontLibraryDialog(
                  context: context,
                  catalogController: harness.catalogController,
                ),
              ),
              child: const Text('Open SF Dialog'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Open SF Dialog'));
    await tester.pumpAndSettle();

    // Verify seeded SF renders.
    expect(
      find.byKey(const Key('soundfont_entry_sf-default')),
      findsOneWidget,
    );

    // Valid .sf2 import adds a second catalog entry.
    final sfBytes = _buildMinimalSf2();
    harness.fileExchange.nextPick = PickedExternalFile(
      fileName: 'Chamber.sf2',
      extension: 'sf2',
      byteLength: sfBytes.length,
      byteStream: Stream<List<int>>.fromIterable(<List<int>>[sfBytes]),
    );
    await tester.tap(find.byKey(const Key('soundfont_import_button')));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(harness.assetRepo.entries.length, 2);

    // Delete imported SoundFont cleanly removes it from catalog.
    await tester.tap(find.byKey(const Key('soundfont_delete_sf-imported-1')));
    await tester.pumpAndSettle();
    expect(harness.assetRepo.entries.length, 1);

    // Web oversized SF2 (> 64 MiB) surfaces fail-closed error banner.
    harness.audioSession.currentPlatform = CalibrationPlatform.web;
    harness.fileExchange.nextPick = PickedExternalFile(
      fileName: 'Huge.sf2',
      extension: 'sf2',
      byteLength: MuseConstants.maxWebSoundFontBytes + 1,
      byteStream: const Stream<List<int>>.empty(),
    );
    await tester.tap(find.byKey(const Key('soundfont_import_button')));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('soundfont_dialog_error_banner')),
      findsOneWidget,
    );
    expect(
      find.textContaining(MuseErrorCode.soundFontTooLargeForWeb.name),
      findsOneWidget,
    );
  });

  testWidgets('LatencyCalibrationDialog handles unattached state and saves sample-rate-derived offset', (
    WidgetTester tester,
  ) async {
    final harness = _ShellHarness();
    addTearDown(harness.dispose);
    harness.audioSession.audioSessionStatus.value = const AudioSessionStatus(
      phase: AudioSessionPhase.requiresWebUserGesture,
    );

    await tester.pumpWidget(
      MaterialApp(
        home: LatencyCalibrationDialog(
          catalogController: harness.catalogController,
          audioSessionController: harness.audioSession,
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(
      find.byKey(const Key('calibration_unattached_warning')),
      findsOneWidget,
    );
    final disabledSave = tester.widget<ElevatedButton>(
      find.byKey(const Key('calibration_save_button')),
    );
    expect(disabledSave.onPressed, isNull);

    // Simulate attached audio hardware at 48 kHz -> +1 ms step == 48 frames.
    await harness.audioSession.ensureAudioInitialized();
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('calibration_step_up_button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('Calibration Offset: 48 frames'), findsOneWidget);

    await tester.tap(find.byKey(const Key('calibration_save_button')));
    await tester.pumpAndSettle();
    expect(harness.assetRepo.savedCalibration?.calibrationOffsetFrames, 48);
  });

  testWidgets('PartMixerSidebar & TransportToolbar bind mixer, M/S, unassigned SF warning, tempo, timing & compact tabs', (
    WidgetTester tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(1360, 820));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final harness = _ShellHarness();
    addTearDown(harness.dispose);
    final created = await harness.catalogController.createBlankProject(
      title: 'Chamber Suite',
      initialSoundFontId: const SoundFontId('sf-default'),
    );
    final projectId = (created as Ok<ProjectSummary>).value.projectId;
    await harness.catalogController.loadCatalogInitial();
    await harness.workspaceController.openProject(projectId);

    await tester.pumpWidget(harness.buildApp());
    await tester.pumpAndSettle();

    final partId =
        harness.workspaceController.currentWorkspace!.aggregate.parts.first.partId;

    // Mute toggle updates workspace part state.
    await tester.tap(find.byKey(Key('part_mute_${partId.value}')));
    await tester.pumpAndSettle();
    expect(
      harness.workspaceController.currentWorkspace!.aggregate.parts.first.isMuted,
      isTrue,
    );

    // Record arm toggle updates TransportAndTelemetryController.
    await tester.tap(find.byKey(Key('part_arm_${partId.value}')));
    await tester.pumpAndSettle();
    expect(harness.transportController.armedPartId, partId);

    // Deleting active SoundFont leaves part unassigned and shows explicit warning.
    unawaited(
      harness.catalogController.deleteSoundFont(
        const SoundFontId('sf-default'),
      ),
    );
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pumpAndSettle();
    expect(
      find.byKey(Key('part_unassigned_sf_${partId.value}')),
      findsOneWidget,
    );

    // Compact mobile viewport (< 840 px) switches to NavigationBar tabs cleanly.
    await tester.binding.setSurfaceSize(const Size(640, 820));
    await tester.pumpAndSettle();
    expect(
      find.byKey(const Key('compact_workspace_navigation')),
      findsOneWidget,
    );
  });

  testWidgets(
    'TransportToolbar shows Loop B1-B4 (including wide meters), updates engine loop frames on BPM edit, and tracks mid-score tempo badge',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 820));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = _ShellHarness();
      addTearDown(harness.dispose);
      final created = await harness.catalogController.createBlankProject(
        title: 'Loop Tempo Audit',
        initialSoundFontId: const SoundFontId('sf-default'),
      );
      final projectId = (created as Ok<ProjectSummary>).value.projectId;
      await harness.catalogController.loadCatalogInitial();
      await harness.workspaceController.openProject(projectId);

      await tester.pumpWidget(harness.buildApp());
      await tester.pumpAndSettle();

      // 1. Toggling Loop in 4/4 sets 0..15360 ticks and displays Loop B1-B4 (not B1-B5).
      await tester.tap(find.byKey(const Key('transport_loop_toggle')));
      await tester.pumpAndSettle();
      expect(
        harness.transportController.loopTickRange,
        (startTick: const Tick(0), endTick: const Tick(15360)),
      );
      expect(find.text('Loop B1-B4'), findsOneWidget);
      expect(harness.bridge.lastLoopRegion?.end, const SampleFrame(384000));

      // 2. Edit Tick-0 BPM 120 -> 60 via toolbar dialog: engine loop end updates to 768000 frames.
      await tester.tap(find.byKey(const Key('transport_tempo_badge')));
      await tester.pumpAndSettle();
      await tester.enterText(
        find.byKey(const Key('transport_tempo_input')),
        '60',
      );
      await tester.tap(find.text('Apply'));
      await tester.pumpAndSettle();
      expect(find.text('60 BPM'), findsOneWidget);
      expect(harness.bridge.lastLoopRegion?.end, const SampleFrame(768000));
      expect(find.text('Loop B1-B4'), findsOneWidget);

      // 3. Insert mid-score tempo (180 BPM at Bar 2 = tick 3840) and move playhead there:
      // badge updates live to 180 BPM, while Tick-0 dialog still pre-fills 60 BPM.
      await harness.workspaceController.executeScoreCommand(
        UpsertTempoEventCommand(
          TempoEventEntity(
            tempoEventId: const TempoEventId('tempo-bar2'),
            projectId: projectId,
            tick: const Tick(3840),
            usPerQuarter: 333333, // 180 BPM
            updatedAtMs: 8000,
          ),
        ),
      );
      harness.transportController.playheadTick.value = const Tick(3840);
      await tester.pumpAndSettle();
      expect(find.text('180 BPM'), findsOneWidget);

      await tester.tap(find.byKey(const Key('transport_tempo_badge')));
      await tester.pumpAndSettle();
      final dialogInput = tester.widget<TextField>(
        find.byKey(const Key('transport_tempo_input')),
      );
      expect(dialogInput.controller?.text, '60');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();

      // 4. Switch to wide 7/4 meter (4 bars = 26880 ticks > 6 whole notes):
      // toggling Loop off then on computes full 4 bars (0..26880) and Loop B1-B4.
      await tester.tap(find.byKey(const Key('transport_loop_toggle')));
      await tester.pumpAndSettle();
      final tick0Ts =
          harness.workspaceController.currentWorkspace!.aggregate.timeSignatureEvents.first;
      await harness.workspaceController.executeScoreCommand(
        UpsertTimeSignatureCommand(
          TimeSignatureEventEntity(
            tsEventId: tick0Ts.tsEventId,
            projectId: projectId,
            tick: const Tick(0),
            numerator: 7,
            denominator: 4,
            updatedAtMs: 8100,
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('transport_loop_toggle')));
      await tester.pumpAndSettle();
      expect(
        harness.transportController.loopTickRange,
        (startTick: const Tick(0), endTick: const Tick(26880)),
      );
      expect(find.text('Loop B1-B4'), findsOneWidget);
    },
  );

  testWidgets(
    'PartMixerSidebar consecutive drag-and-drop reorders update both sidebar order and StaffSystemView every time',
    (WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1360, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));

      final harness = _ShellHarness();
      addTearDown(harness.dispose);
      final created = await harness.catalogController.createBlankProject(
        title: 'Trio Reorder',
        initialSoundFontId: const SoundFontId('sf-default'),
      );
      final projectId = (created as Ok<ProjectSummary>).value.projectId;
      await harness.catalogController.loadCatalogInitial();
      await harness.workspaceController.openProject(projectId);

      // Add Violin and Cello so we have 3 parts: Piano, Violin, Cello.
      expect(
        (await harness.workspaceController.addPart(
          name: 'Violin',
          stavesCount: 1,
          sfId: const SoundFontId('sf-default'),
          bankNum: 0,
          programNum: 40,
          initialClefSign: ClefSign.G,
          initialClefLine: 2,
        ))
            .isOk,
        isTrue,
      );
      expect(
        (await harness.workspaceController.addPart(
          name: 'Cello',
          stavesCount: 1,
          sfId: const SoundFontId('sf-default'),
          bankNum: 0,
          programNum: 42,
          initialClefSign: ClefSign.F,
          initialClefLine: 4,
        ))
            .isOk,
        isTrue,
      );

      await tester.pumpWidget(harness.buildApp());
      await tester.pumpAndSettle();

      final initialParts =
          harness.workspaceController.currentWorkspace!.aggregate.parts;
      expect(initialParts.map((p) => p.name).toList(), <String>[
        'Piano',
        'Violin',
        'Cello',
      ]);

      final pianoId = initialParts[0].partId;
      final violinId = initialParts[1].partId;
      final celloId = initialParts[2].partId;

      List<String> sidebarOrderByY() {
        final entries = <(double y, String name)>[
          (
            tester.getCenter(find.byKey(Key('part_drag_handle_${pianoId.value}'))).dy,
            'Piano',
          ),
          (
            tester.getCenter(find.byKey(Key('part_drag_handle_${violinId.value}'))).dy,
            'Violin',
          ),
          (
            tester.getCenter(find.byKey(Key('part_drag_handle_${celloId.value}'))).dy,
            'Cello',
          ),
        ]..sort((a, b) => a.$1.compareTo(b.$1));
        return entries.map((e) => e.$2).toList();
      }

      List<String?> staffScoreInstruments() {
        final view = tester.widget<StaffSystemView>(
          find.byType(StaffSystemView),
        );
        return view.system.staves.map((s) => s.metadata.instrument).toList();
      }

      expect(sidebarOrderByY(), <String>['Piano', 'Violin', 'Cello']);
      expect(staffScoreInstruments(), <String?>['Piano', 'Violin', 'Cello']);

      // Drag 1: Move Piano down so its bottom lands in Violin's lower half -> [Violin, Piano, Cello].
      final pianoCard1 = find.byKey(ValueKey<String>(pianoId.value));
      final violinCard1 = find.byKey(ValueKey<String>(violinId.value));
      final pianoHandle1 = find.byKey(Key('part_drag_handle_${pianoId.value}'));
      final step1 = tester.getTopLeft(violinCard1).dy - tester.getTopLeft(pianoCard1).dy;
      await tester.drag(pianoHandle1, Offset(0, step1 * 0.75));
      await tester.pumpAndSettle();

      expect(
        harness.workspaceController.currentWorkspace!.aggregate.parts
            .map((p) => p.name)
            .toList(),
        <String>['Violin', 'Piano', 'Cello'],
      );
      expect(sidebarOrderByY(), <String>['Violin', 'Piano', 'Cello']);
      expect(staffScoreInstruments(), <String?>['Violin', 'Piano', 'Cello']);
      expect(
        harness.notationController.layoutStaffSlots
            .map((s) => s.partId)
            .toList(),
        <PartId>[violinId, pianoId, celloId],
      );

      // Drag 2: Move Cello up so its top lands in Violin's upper half -> [Cello, Violin, Piano].
      final celloCard2 = find.byKey(ValueKey<String>(celloId.value));
      final violinCard2 = find.byKey(ValueKey<String>(violinId.value));
      final celloHandle2 = find.byKey(Key('part_drag_handle_${celloId.value}'));
      final dragDelta2 =
          tester.getTopLeft(violinCard2).dy -
          tester.getTopLeft(celloCard2).dy +
          20;
      await tester.drag(celloHandle2, Offset(0, dragDelta2));
      await tester.pumpAndSettle();

      expect(
        harness.workspaceController.currentWorkspace!.aggregate.parts
            .map((p) => p.name)
            .toList(),
        <String>['Cello', 'Violin', 'Piano'],
      );
      expect(sidebarOrderByY(), <String>['Cello', 'Violin', 'Piano']);
      expect(staffScoreInstruments(), <String?>['Cello', 'Violin', 'Piano']);
      expect(
        harness.notationController.layoutStaffSlots
            .map((s) => s.partId)
            .toList(),
        <PartId>[celloId, violinId, pianoId],
      );

      // Drag 3: Move Violin down so its bottom lands in Piano's lower half -> [Cello, Piano, Violin].
      final violinCard3 = find.byKey(ValueKey<String>(violinId.value));
      final pianoCard3 = find.byKey(ValueKey<String>(pianoId.value));
      final violinHandle3 = find.byKey(Key('part_drag_handle_${violinId.value}'));
      final step3 = tester.getTopLeft(pianoCard3).dy - tester.getTopLeft(violinCard3).dy;
      await tester.drag(violinHandle3, Offset(0, step3 * 0.75));
      await tester.pumpAndSettle();

      expect(
        harness.workspaceController.currentWorkspace!.aggregate.parts
            .map((p) => p.name)
            .toList(),
        <String>['Cello', 'Piano', 'Violin'],
      );
      expect(sidebarOrderByY(), <String>['Cello', 'Piano', 'Violin']);
      expect(staffScoreInstruments(), <String?>['Cello', 'Piano', 'Violin']);
      expect(
        harness.notationController.layoutStaffSlots
            .map((s) => s.partId)
            .toList(),
        <PartId>[celloId, pianoId, violinId],
      );
    },
  );
}
