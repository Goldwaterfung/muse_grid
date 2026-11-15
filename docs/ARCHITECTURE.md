# Architecture — MuseGrid

**MuseGrid** is a cross-platform (iOS, Android, Web) music notation, dynamic grid, SoundFont playback, and real-time recording platform built with **Flutter/Dart** and a **unified C/C++ + WebAssembly audio engine**.

This document defines MuseGrid's **5-layer + Middle Bridge architecture** aligned with [requirements.md](file:///Users/goldenfung/Documents/muse_grid/requirements.md), establishing strict separation between real-time audio processing, cross-platform notation/musical state, and UI workflows.

---

## Table of Contents

1. [Architectural Philosophy](#1-architectural-philosophy)
2. [The 5-Layer Hierarchy](#2-the-5-layer-hierarchy)
3. [Layer 1 — Platform Audio HAL](#3-layer-1--platform-audio-hal)
4. [Layer 2 — Core Real-Time Infrastructure](#4-layer-2--core-real-time-infrastructure)
5. [Layer 3 — Core Audio & Synthesis Engine](#5-layer-3--core-audio--synthesis-engine)
6. [Middle Bridge (Platform-Agnostic Audio Facades)](#6-middle-bridge-platform-agnostic-audio-facades)
7. [Layer 4 — Musical Composition & Notation Domain](#7-layer-4--musical-composition--notation-domain)
8. [Layer 5 — Presentation (Flutter UI)](#8-layer-5--presentation-flutter-ui)
9. [Composition Root](#9-composition-root)
10. [Storage & Persistence Architecture (SQLite + Content-Addressed Storage)](#10-storage--persistence-architecture-sqlite--content-addressed-storage)
11. [Data Flow & Synchronization](#11-data-flow--synchronization)
12. [Threading & Execution Model (Native vs. Web)](#12-threading--execution-model-native-vs-web)
13. [Planned Repository Layout](#13-planned-repository-layout)

---

## 1. Architectural Philosophy

Every layer depends **only downward**—never upward. Real-time audio processing is strictly isolated in C/C++ (Native) and Wasm `AudioWorklet` (Web), while musical state, MusicXML, and UI rendering live in Pure Dart and Flutter.

### Dependency Graph

```text
lib/app/ (Composition Root)
  │
  ▼
Presentation (L5: Flutter UI)
  │
  ▼
Musical & Notation Domain (L4: Pure Dart + crisp_notation_core + 960 PPQN)
  │
  ▼ (imports Pure Dart contracts only: lib/bridge/contracts/)
Middle Bridge (lib/bridge/contracts/ ◀── implemented by native/ [FFI] & web/ [AudioWorklet], wired in lib/app/)
  │
  ▼
Core Audio & Synthesis Engine (L3: FluidSynth + 3-Phase Cycle + Capture/Telemetry)
  │
  ▼
Core Real-Time Infrastructure (L2: Lock-Free SPSC Queues, POD Types, Sample Clock)
  │
  ▼
Platform Audio HAL (L1: miniaudio Duplex [Native] / Web Audio AudioWorklet [Web])
```

### Core Architectural Invariants

- **Fixed Deterministic Audio Graph:** Audio synthesis and microphone capture run over a single, predictable signal graph (`FluidSynth` + `Mic Input` → `Monitor/Gain` → `Master Limiter`) with zero dynamic allocations on the real-time thread.
- **Pure Dart Musical Domain (L4):** Score state, MusicXML codecs (`crisp_notation_core`), and the `960 PPQN` timeline stay in Pure Dart (`WasmGC`-ready) so Flutter UI interactions do not cross FFI/Wasm boundaries per frame. L4 may import only Pure Dart bridge contracts (`lib/bridge/contracts/`) and never `dart:ffi`, `dart:io`, or `package:web`.
- **Platform-Agnostic Middle Bridge & Storage Separation:** Flutter UI (L5) interacts with audio hardware strictly through segregated audio Bridge contract facades (`lib/bridge/contracts/`), while platform audio implementations (`lib/bridge/native/` using `dart:ffi`; `lib/bridge/web/` using `package:web` `MessagePort`) and platform storage backends (`lib/storage/native/` using SQLite FFI + `path_provider`; `lib/storage/web/` using `sqlite3.wasm` + OPFS) are wired exclusively by the Composition Root (`lib/app/`).

---

## 2. The 5-Layer Hierarchy

| Layer | Name | Runtime / Language | Responsibility |
| :--- | :--- | :--- | :--- |
| — | **Composition Root** | Dart (`lib/app/`) | Dependency injection, lifecycle, platform audio & storage backend selection |
| **5** | **Presentation** | Flutter (`CustomPainter`, `crisp_notation`) | 5-line staff views, custom Piano Roll Dynamic Grid, transport/recording UI |
| **4** | **Musical & Notation Domain** | Pure Dart (`crisp_notation_core`) | Canonical `960 PPQN` timeline, MusicXML codecs, quantize/snap, undo/redo |
| **Bridge** | **Middle Bridge** | Dart (`dart:ffi` / `package:web`) | Segregated controller facades & POD boundary messages |
| **3** | **Core Audio & Synthesis Engine** | C/C++ (Native & Emscripten Wasm) | `FluidSynth` SF2 synth, 3-phase audio cycle, epoch-gated scheduler, capture/telemetry taps |
| **2** | **Core Real-Time Infrastructure** | C/C++ | Lock-free SPSC ring buffers, POD structs, monotonic sample clock |
| **1** | **Platform Audio HAL** | C/C++ & Browser Web Audio | `miniaudio` (`ma_device_type_duplex`) on Native; `AudioContext` + `AudioWorklet` + `MediaStream` on Web |

---

## 3. Layer 1 — Platform Audio HAL

Quarantines all OS and browser audio/microphone APIs behind a single audio device boundary so there is **one audio session owner** and **one hardware clock** per platform.

* **Native (iOS, Android, macOS, Windows, Linux) — `miniaudio` (`ma_device_type_duplex`):**
  * Opens simultaneous playback (`pOutput`) and microphone capture (`pInput`) in a single callback.
  * **iOS:** Configures `AVAudioSession` once via `ma_context_config` (`ma_ios_session_category_play_and_record` + speaker/Bluetooth routing options) and declares `NSMicrophoneUsageDescription` in `ios/Runner/Info.plist`.
  * **Android:** Requires `RECORD_AUDIO` runtime permission before `ma_device_init`; matches native sample rate (typically 48 kHz) for AAudio low-latency mode with safe shared-mode fallback on OEM drivers.
* **Web — Web Audio API (`AudioContext` + `AudioWorklet` + `MediaStream`):**
  * Connects `MediaStreamAudioSourceNode` (microphone) and an Emscripten-compiled Wasm `AudioWorkletProcessor` into the same `AudioContext` sample clock.
  * Defers `AudioContext.resume()` and `getUserMedia` until an explicit user gesture over HTTPS/`localhost` (with `COOP`/`COEP` headers if using `SharedArrayBuffer`).

---

## 4. Layer 2 — Core Real-Time Infrastructure

Provides zero-allocation, lock-free primitives shared across both the native C++ engine and the Emscripten Wasm core:

* **Lock-Free Bridges (SPSC Ring Buffers):**
  * `MutationQueue` (UI/Bridge → Audio Thread): transport state, `FlushAndAdvanceEpoch(newEpoch)` commands, SoundFont bank/program changes, gain/monitoring toggles.
  * `EventQueue` (UI/Bridge → Audio Thread): epoch-tagged, sample-timestamped MIDI events (`epoch`, `noteOn`, `noteOff`, `cc`, `pitchBend`, `targetSampleFrame`).
  * `CaptureRingBuffer` (Audio Thread → Background Worker): raw `f32` microphone frames + latched `{capturedSampleClock, capturedPlayheadFrame}` timestamps on Native (and SAB Web); when `SharedArrayBuffer` is unavailable on Web, `AudioWorkletProcessor` accumulates frames into a pre-allocated batch buffer and transfers pooled `Float32Array` `ArrayBuffer` chunks via `MessagePort` every `kWebCaptureBatchQuanta` blocks. On ring/batch overflow, the engine sets an overflow flag in `TelemetryFrame` and fails closed by aborting capture with `CAPTURE_BUFFER_OVERFLOW` rather than silently truncating audio.
  * `TelemetryQueue` (Audio Thread → Bridge): batched peak/RMS meters, `playheadSampleFrame`, buffer underrun flags, and block peak/RMS recording waveform summaries (FFT/analysis frames are deferred out of the current scope).
* **POD Boundary Types:** Trivially copyable structs with fixed sizes (no heap allocations, no `std::string`, no mutexes inside the audio callback).
* **Clock & Tempo Mapping:** L2 exposes only the monotonic hardware `sampleClock` counter; all `tick` ↔ `sampleFrame` conversion is owned exclusively by L4 (`lib/domain/`).

---

## 5. Layer 3 — Core Audio & Synthesis Engine

A deterministic, fixed-topology audio and SoundFont engine shared across native and Web Wasm.

### Fixed Signal Graph

```text
[MIDI EventQueue] ──────▶ [FluidSynth (SF2)] ───────┐
[TakePlaybackRingBuffer] ─▶ [Per-Part WAV Streams] ─┼──▶ [Master Bus + Soft Limiter] ──▶ pOutput (Speakers)
[Mic pInput] ──┬──────────▶ [Optional Monitor Gain] ┘
               │
               └───▶ [CaptureRingBuffer / Batched Transfer] ──▶ [Butler Worker (WAV + SHA-256)]
                                                                       │ (metadata via IRecordingBridge)
                                                                       ▼
                                                                [lib/storage/ (CAS + SQLite)]
```

### 3-Phase Audio Callback

1. **`startCycle()`:** Advance hardware `sampleClock`, consume pending `MutationQueue` commands (`MUT_SET_PLAYING`, `MUT_SEEK_SAMPLE`, `MUT_SET_LOOP_REGION`, `MUT_FLUSH_AND_ADVANCE_EPOCH`, `MUT_SET_SYNTH_SUSPENDED`, monitor/mix/patch/capture state), latch active transport state and `activeEpoch` (emitting safe `noteOff` / voice resets on epoch advance), and suppress loop-wrap while `is_capturing` is active so recorded audio remains linear on the timeline.
2. **`processAudio()`:** If `synth_suspended` is active (during Native SF2 load/unload), acknowledge via atomic and render silence on the synth bus; otherwise drain due `EventQueue` events matching `[playheadSampleFrame, playheadSampleFrame + frameCount)` (or `kImmediateDispatchFrame` for live audition, discarding `event.epoch < activeEpoch`) and split-render `FluidSynth` (`f32`) sample-accurately across event offsets. Mix active `TakePlaybackRingBuffer` frames matching the playhead, mix optional low-latency monitor gain, apply master soft limiter to `pOutput`, and copy `pInput` into `CaptureRingBuffer` (latching `{capturedSampleClock, capturedPlayheadFrame}` on the first captured frame). Push `TelemetryFrame` snapshots (peaks/RMS/playhead/underruns) to `TelemetryQueue`.
3. **`endCycle()`:** Advance `playheadSampleFrame` when playing (wrapping at `loopEndFrame` only when not capturing) and signal the non-real-time Butler worker via an RT-safe atomic wake flag (native) or post a full pre-allocated capture `ArrayBuffer` batch over `MessagePort` (Web non-SAB) when capture buffers reach threshold.

### SoundFont & Disk I/O Offloading

* **`FluidSynth` (`libfluidsynth`, SF2-Only):** Provides full **SF2** spec compliance (modulators, per-voice resonant filters, built-in reverb and chorus). SF3 is excluded in the current architecture so `libsndfile`/Ogg-Vorbis need not be bundled. Compiled for both Native and Emscripten Wasm as a minimal, thread-free static core (`-Dosal=cpp11` on Native / `-Dosal=embedded` on Wasm, `-Denable-libinstpatch=0`, `-Denable-threads=OFF`, `-Denable-libsndfile=OFF`) with **`synth.threadsafe-api = 0`** so zero mutexes are acquired on the RT audio thread, rendering via `fluid_synth_write_float()` inside `processAudio()`. On Native, Butler `fluid_synth_sfload()` / `fluid_synth_sfunload()` runs under an explicit atomic **suspend → load/unload → resume** handshake (`MUT_SET_SYNTH_SUSPENDED`) so it never races with RT rendering. (Static linking of LGPL-2.1 `FluidSynth` requires LGPL distribution compliance review for iOS and Web.)
* **Channel Capacity:** One `FluidSynth` instance exposes 16 MIDI channels (`0..15`, with channel `9` reserved for GM percussion), bounding single-instance part routing at 16 channels (`kMidiChannelCount = 16`). Recorded WAV playback (`TakePlaybackRingBuffer`) is likewise bounded at 1 overwrite recording per part (`kMaxActiveTakeRegions = 16`).
* **Web Non-SAB SoundFont Load Policy:** When `SharedArrayBuffer` is unavailable, FluidSynth's Wasm heap lives inside `AudioWorkletGlobalScope`, so `fluid_synth_sfload()` must run inside the worklet. To preserve RT safety, Web SoundFont loading is permitted **only while transport is stopped** (emitting silence during load) and is gated fail-closed by a centralized maximum SoundFont byte cap (`kMaxWebSoundFontBytes`) to prevent worklet OOM on mobile browsers (e.g., iOS Safari).
* **Non-RT Worker ("Butler") & Storage Separation:** On Native, the Butler worker loads `.sf2` assets (under the suspend handshake), decodes/resamples active per-part `.wav` recordings into `TakePlaybackRingBuffer`, and encodes start/stop-only recorded PCM to raw **WAV** (`ma_encoding_format_wav` via `ma_encoder`) inside `ApplicationSupportDirectory/staging/rec_<take_id>.wav.part`, finalizes WAV header chunk sizes on stop, computes the SHA-256 digest sequentially over the finalized file, and returns `{stagingPath, sha256, durationFrames, sampleRate, channelCount, capturedPlayheadFrame, capturedSampleClock, outputBufferFrames, inputBufferFrames}` across `IRecordingBridge`. On Web, a dedicated Web Worker streams batched capture chunks to OPFS `staging/`, finalizes WAV headers, computes SHA-256, and decodes/resamples active part `.wav` files into `TakePlaybackRingBuffer`. In both platforms, the **Dart storage adapter (`lib/storage/`)**—never L3—owns atomic promotion into `cas/` and the single SQLite overwrite `UPSERT` (`UNIQUE (project_id, part_id)`).

---

## 6. Middle Bridge (Platform-Agnostic Audio Facades)

Decouples the Pure Dart Domain (L4) and Flutter Presentation (L5) from how the real-time audio engine is hosted (`dart:ffi` + `ffigen` on Native vs. `package:web` + `MessagePort` on Web). Persistence and file-system adapters are intentionally separated into `lib/storage/` (see [Section 10](#10-storage--persistence-architecture-sqlite--content-addressed-storage)).

### Contract vs. Platform Implementation Split

To preserve L4 Pure Dart / WasmGC isolation:
* **`lib/bridge/contracts/` (Pure Dart):** Defines the segregated audio bridge interfaces and fixed-size POD transfer models. Safe for L4 (`lib/domain/`) and L5 (`lib/presentation/`) to import.
* **`lib/bridge/native/` (`dart:ffi` + `ffigen`) & `lib/bridge/web/` (`package:web` + `dart:js_interop`):** Platform-specific implementations imported **exclusively** by the Composition Root (`lib/app/`) and test harnesses.

### Segregated Bridge Interfaces

| Interface | Responsibility |
| :--- | :--- |
| `IAudioLifecycleBridge` | Engine init/dispose, SoundFont loading (via storage-resolved internal path on Native or byte stream into stopped worklet on Web, bounded by `kMaxWebSoundFontBytes`), hardware sample rate/buffer queries |
| `ITransportBridge` | Play, pause, stop, seek (in ticks/samples), loop range, count-in |
| `ISynthEventBridge` | Epoch-tagged bounded lookahead MIDI scheduling (`noteOn`/`noteOff`/`cc`) ahead of playhead, `FlushAndAdvanceEpoch` invalidation on seek/edit, live key audition |
| `IRecordingBridge` | Start/stop raw **WAV** capture into staging (`staging/rec_<take_id>.wav.part` on Native or OPFS `staging/` on Web), returning finalized `{stagingPath, sha256, durationFrames, sampleRate, channelCount, capturedPlayheadFrame, capturedSampleClock, outputBufferFrames, inputBufferFrames}` to `lib/storage/` |
| `ITelemetryBridge` | Single-drainer 30–60Hz playhead `playheadSampleFrame` (plus cached `latestSnapshot` for L4 lookahead), input/output peak/RMS levels, recording waveform peak/RMS blocks, underrun flags, round-trip latency calibration offset |

---

## 7. Layer 4 — Musical Composition & Notation Domain

Pure Dart layer (`WasmGC`-compatible, zero Flutter widget, `dart:io`, `dart:ffi`, or `package:web` dependencies). Serves as the **single source of truth** for musical structure:

* **Canonical Tick Timeline (`960 PPQN`, 1 Whole = `3840` ticks):**
  * Integer tick storage covering all target rhythmic subdivisions:
    * **Straight (up to `1/64`):** `1/1` (`3840`), `1/2` (`1920`), `1/4` (`960`), `1/8` (`480`), `1/16` (`240`), `1/32` (`120`), `1/64` (`60`)
    * **Dotted (up to Dotted `1/32`):** Dotted `1/2` (`2880`), Dotted `1/4` (`1440`), Dotted `1/8` (`720`), Dotted `1/16` (`360`), Dotted `1/32` (`180`)
    * **Triplets (up to `1/32T`):** `1/2T` (`1280`), `1/4T` (`640`), `1/8T` (`320`), `1/16T` (`160`), `1/32T` (`80`)
  * Tempo map and time-signature map (together with `pickup_ticks`) are owned exclusively by L4 to convert deterministically between `tick` ↔ `musical position (bar:beat)` ↔ `sampleFrame` using segment-wise 64-bit integer arithmetic.
* **Dual-Model Synchronization (`960 PPQN` Grid ↔ `crisp_notation_core` `0.14.0+`):**
  * Handles MusicXML (`.xml` / `.musicxml` / `.mxl`) bidirectional **import and export** via `crisp_notation_core` (`readMusicXmlFromMxl` / `writeMusicXmlToMxl` and `multiPartScoreFromMusicXml` / `multiPartToMusicXml`; no MusicXML snapshot is persisted in CAS), music theory models, and deterministic staff layout (`MultiPartScore` ↔ `StaffSystem`).
  * Links each `TimelineNoteEvent` (`rawStartTick`, `rawDurationTicks`, `quantizedStartTick`, `quantizedDurationTicks`, `velocity`) to its corresponding `crisp_notation_core` `NoteElement` via a **shared stable `noteId`**, backed by authoritative `note_spanners` (ties, slurs, beams keyed by `noteId`), `key_signature_events`, and `clef_events` tables. *(Early Phase 0 spike verifies `crisp_notation_core` preserves caller-assignable `NoteElement.id` values across edits and MusicXML round-trips.)*
  * Synchronizes edits in-place rather than destructively regenerating the staff from raw ticks, preserving staff engraving metadata (enharmonic spelling such as `C#` vs. `Db`, voice/staff assignment, beams, slurs, ties across barlines) alongside unquantized Piano Roll performance timing.
* **Project & Editing Commands:**
  * Undo/redo command stack, snap-to-grid quantization, note CRUD, velocity editing, and lookahead playback event compilation (`raw` vs. `quantized` timing per `projects.playback_timing_mode`) for `ISynthEventBridge`.
* **Persistence Contracts (SQLite + Content-Addressed Storage):**
  * Defines Pure Dart repository contracts (`IProjectRepository`, `IAssetLibraryRepository`) in `lib/domain/` where relational SQLite tables are the **single source of truth** for score state (project catalog, `noteId`-linked `timeline_notes`, `note_spanners`, key/clef/tempo/time-signature maps, take registries, calibration profiles), separate from immutable SHA-256 Content-Addressed Storage (`cas/<aa>/<sha256>.{sf2|wav}`).
  * Eliminates `.musegrid` (`.zip`) bundle packing so score edits are $O(1)$ SQLite commits and recorded WAV takes are finalized in `staging/`, hashed sequentially, and promoted into `cas/` by `lib/storage/`. Full schema and CAS layout live in [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md).
  * Platform storage adapters (`lib/storage/native/` using SQLite FFI + `dart:io` + `path_provider`; `lib/storage/web/` using `sqlite3.wasm` + OPFS via `package:web`) live outside L4 and are injected by `lib/app/` (with a future `lib/storage/cloud/` delta-sync adapter slot).

---

## 8. Layer 5 — Presentation (Flutter UI)

Cross-platform Flutter UI consuming only **L4 Domain** and **Middle Bridge** facades:

* **Standard 5-Line Staff Notation (`crisp_notation` `0.14.0+`):**
  * Interactive staff widgets (`StaffView`, `InteractiveStaff`, `StaffSystemView`) using the bundled Bravura SMuFL font.
  * Uses `StaffSystemView`'s `gridAlign` engraving rule for vertical cross-staff onset alignment on grand staves and ensemble scores.
* **Dynamic Grid Notation (Custom Piano Roll Module):**
  * Viewport-culled `CustomPainter` / custom `RenderBox` rendering visible pitch × time ranges at 60/120 fps.
  * Adaptive bar/beat/subdivision grid lines (`1/64`–`1/1`, dotted, triplets) with zoom-dependent level-of-detail (LOD), velocity lane, and a separate animated playhead overlay layer.
  * Supports both mobile touch (pinch-zoom, tap/drag) and Web/desktop pointer workflows (wheel zoom, hover edge-resize, marquee selection, keyboard shortcuts).
* **Recording & Metering Views:**
  * Driven by a centralized 30–60Hz `Ticker` / stream reading `ITelemetryBridge` (playhead sync, input clipping meter, recording waveform).

---

## 9. Composition Root

Located in `lib/app/`:

* Instantiates the platform-appropriate audio Middle Bridge (`NativeAudioBridge` on iOS/Android/desktop vs. `WebAudioWorkletBridge` on Web) and platform storage backend (`NativeStorageAdapter` vs. `WebOpfsStorageAdapter`, plus future cloud sync).
* Wires L4 Domain services and L5 Presentation view-models/controllers.
* Manages app startup/shutdown sequencing (permission checks, Web `navigator.storage.persist()` & quota verification, SoundFont preload, audio engine lifecycle, graceful teardown on background/dispose).

---

## 10. Storage & Persistence Architecture (SQLite + Content-Addressed Storage)

MuseGrid separates **authoritative relational score & metadata state** (handled via local SQLite CRUD during development, behind Pure Dart repositories ready for future cloud delta-sync) from **immutable content-addressed binary media** (recorded raw `.wav` takes and `.sf2` SoundFonts) stored on the platform file system or browser OPFS. MusicXML (`.xml` / `.musicxml` / `.mxl`) is an import/export exchange format only, not a persisted CAS snapshot. The complete relational schema, table constraints, indexes, and on-disk CAS layout are specified in [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md).

### 10.1 Hybrid SQLite + Content-Addressed Store (Local CRUD → Cloud Ready)

* **Authoritative Score & Metadata in SQLite (`db/musegrid.db`):**
  * Serves as the single source of truth via indexed SQLite tables (`projects`, `project_parts`, `tempo_events`, `time_signature_events`, `key_signature_events`, `clef_events`, `timeline_notes`, `note_spanners`, `audio_takes`, `soundfonts`, `soundfont_presets`, `latency_calibration_profiles`, and `content_blobs` — see [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md)).
  * Uses `UUIDv7` primary keys, `updated_at` timestamps, `revision` counters, and soft-delete tombstones (`deleted_at` on top-level `projects` and `soundfonts`; `audio_takes` stores at most 1 overwrite recording per part via `UNIQUE (project_id, part_id)` with undoable deletion) so local CRUD transitions cleanly to incremental cloud delta-sync.
  * **Single-Writer Ownership & Journal Mode:** `lib/storage/` owns the single SQLite writer connection on each platform (no L3 C++/Wasm worker writes directly to SQLite). Native uses `PRAGMA journal_mode = WAL`; Web `sqlite3.wasm` over OPFS uses the default rollback journal (`DELETE`/`TRUNCATE`) because browser OPFS lacks POSIX shared memory for WAL. Startup verifies `PRAGMA journal_mode;` and fails closed on mismatch.
  * **Why Binary Blobs Stay Out of SQLite:** Keeping large `.sf2` SoundFonts and multi-minute `.wav` takes in immutable `cas/` files rather than SQLite `BLOB`s avoids database bloat and lets `FluidSynth` and `ma_encoder` stream directly from storage.
* **Cross-Platform SQLite Runtime:**
  * **Native (iOS, Android, Desktop):** `sqlite3` FFI (via Dart Build Hooks) against `db/musegrid.db` inside `ApplicationSupportDirectory`.
  * **Web (`flutter build web --wasm`):** `sqlite3.wasm` backed by the **OPFS VFS** inside a dedicated Web Worker for ACID persistence without blocking the UI thread.
* **Cloud Migration Path:** L4 (`lib/domain/`) depends only on `IProjectRepository` and `IAssetLibraryRepository`. Once the local architecture stabilizes, a future `lib/storage/cloud/` adapter (remote CRUD API + object storage for `cas/` blobs) can sync only changed SQLite rows and newly hashed audio/SoundFont blobs without changing L4 or L5.

### 10.2 Content-Addressed Storage (CAS) & Finalize-Then-Hash Recording (No `.zip` Packing)

MuseGrid intentionally **drops `.musegrid` (`.zip`) bundle archives** to eliminate CPU bottlenecks on `.wav` audio, 2× temporary storage spikes, Wasm/isolate heap pressure, and write amplification on small score edits:

* **Immutable CAS Layout (`cas/<aa>/<sha256>.<ext>`):** Binary payloads (`.sf2` SoundFonts and recorded `.wav` takes) are deduplicated by lowercase SHA-256 digest in `content_blobs` and reclaimed via **mark-and-sweep GC** (eliminating `ref_count` drift across cascading deletes).
* **Finalize-Then-Hash WAV Capture (1 Overwrite Recording per Part):** During recording on a part, other unmuted parts play back normally while the armed part's previous WAV is suppressed. The Butler worker encodes `CaptureRingBuffer` frames as raw WAV (`ma_encoding_format_wav` via `ma_encoder`) into `staging/rec_<take_id>.wav.part`. On `stop()`, `ma_encoder_uninit()` patches the final RIFF/`data` chunk sizes in the WAV header, the worker computes the SHA-256 digest sequentially over the finalized file, and `lib/storage/` (Dart) promotes the file to `cas/<aa>/<sha256>.wav` and `UPSERT`s `content_blobs` + `audio_takes` (`UNIQUE (project_id, part_id)`) in one SQLite transaction—leaving any superseded `.wav` blob to Mark-and-Sweep GC. *(External `.sf2` imports are already finalized and may stream-hash in a single pass.)*
* **Direct Standard Import / Export:** Score edits commit directly to `timeline_notes` / `note_spanners` + `projects` in milliseconds; user import/export operates directly on standard `.musicxml`/`.mxl`, `.sf2`, and `.wav` files.

### 10.3 Native File Access (`path_provider` & OS Pickers)

iOS and Android enforce app sandboxing and external-URI restrictions that C/C++ `fopen()` cannot bypass directly:

| Directory (`path_provider`) | OS Behavior (iOS / Android) | MuseGrid Usage |
| :--- | :--- | :--- |
| **Application Support** (`getApplicationSupportDirectory()`) | Private, persistent across updates; not user-editable. On iOS, subfolders can set `NSURLIsExcludedFromBackupKey = true`. | `db/musegrid.db` (plus `-wal`/`-shm`), `staging/` (same volume as `cas/` so `rename()` is atomic and mid-recording files are never purged by the OS; startup sweeps orphaned `.part` files), and `cas/` content-addressed blobs (`.wav` takes and `.sf2` SoundFonts excluded from iCloud backup to avoid quota exhaustion). |
| **Temporary / Cache** (`getTemporaryDirectory()`) | Ephemeral; OS may purge under low disk space. | Transient OS share/export staging (`Stage-on-Export`) before handing files to the OS save/share sheet. Never holds `db/musegrid.db`, `staging/` recordings, or committed takes. |
| **Documents** (`getApplicationDocumentsDirectory()`) | User-visible (iOS Files app) and backed up automatically. | User-initiated exports (`.musicxml`/`.mxl` scores, bounced/exported `.wav` audio). |

* **Copy-on-Import / Stage-on-Export (SAF & iOS Document Picker):** Android Storage Access Framework returns `content://` URIs and iOS `UIDocumentPickerViewController` returns temporary security-scoped URLs—neither can be reliably opened by C/C++ `FluidSynth` or `ma_encoder` across sessions. Native storage adapters **hash & copy imported `.sf2` files into `ApplicationSupportDirectory/cas/`** on import (registering `content_blobs` + domain rows in SQLite) and **stage exports in `TemporaryDirectory`** before handing them to the OS save/share sheet.

### 10.4 Web File Access (OPFS, Quota Management & Browser Matrix)

| Web API | Browser Support | Role in MuseGrid |
| :--- | :--- | :--- |
| **OPFS** (`navigator.storage.getDirectory()`) | Universal (Chrome 102+, Edge, Firefox 111+, Safari 15.2+ desktop & iOS) | **Primary Web store.** Inside a Web Worker, `FileSystemSyncAccessHandle` gives synchronous, near-native byte-range `read()`/`write()`/`flush()` for `db/musegrid.db` (`sqlite3.wasm` rollback journal), streaming `WAV` recordings into `staging/` → `cas/` (checking `FileSystemHandle.move()` support or writing verified CAS directly if unavailable), and cached `.sf2` SoundFonts. |
| **File System Access API** (`showOpenFilePicker` / `showSaveFilePicker`) | Chromium desktop only (unsupported on Safari & Firefox) | Optional enhancement for direct "Save As" on Chromium desktop; never assumed as the primary backend. |
| **IndexedDB** | Universal | Explicit, logged degraded mode only if OPFS `FileSystemSyncAccessHandle` is unavailable in the browser context; fails closed with an explicit storage error if persistent storage cannot be initialized. |

* **Eviction Protection & Fail-Closed Quota Guards:**
  * Browser storage defaults to "Best-Effort" and can be silently evicted under disk pressure (notably on Safari). On startup/first write, the Web storage adapter requests `await navigator.storage.persist()`.
  * Before downloading/caching a SoundFont or starting a recording, the Web adapter queries `navigator.storage.estimate()` (`quota - usage`) and checks SoundFont size against `kMaxWebSoundFontBytes`, **failing closed** with an explicit `INSUFFICIENT_STORAGE_QUOTA` or `SOUNDFONT_TOO_LARGE` error if limits are violated.
* **Cross-Browser Import / Export:** Imports read from `<input type="file">` (or drag-and-drop), parsing `.musicxml`/`.mxl` into L4/SQLite or streaming `.sf2` `File` `Blob`s through SHA-256 hashing into OPFS `cas/`; exports read `.wav` from OPFS `cas/` or serialize `.musicxml`/`.mxl` from L4 and use `showSaveFilePicker()` where supported or standard `Blob` download / Web Share across Safari and Firefox.

---

## 11. Data Flow & Synchronization

### Editing & Playback Loop (Bounded Lookahead Window)

To keep the fixed-capacity `EventQueue` (L2) bounded and responsive to live edits without score-length queue overflows:
1. Decoupled from the Flutter UI paint ticker (dedicated non-paint timer on Native/Web with explicit `EVENT_QUEUE_UNDERRUN` telemetry if refills stall past the scheduled watermark), the playback feeder reads the cached `ITelemetryBridge.latestSnapshot` playhead (while L5 owns the single destructive `drainTelemetry()` call) and schedules monotonically non-decreasing, sorted batches for a rolling lookahead window (`[playhead, playhead + kLookaheadWindowMs]`, centralized constant e.g. 200 ms) into `ISynthEventBridge`, reading `raw_*` or `quantized_*` note timing per `projects.playback_timing_mode`.
2. On `seek`, tempo-map mutation, or live note edit inside the lookahead horizon, L4/Bridge advances the monotonic epoch and issues `FlushAndAdvanceEpoch(newEpoch)` on `MutationQueue`. `startCycle()` updates `activeEpoch` and emits safe `noteOff`/reset for active voices, `processAudio()` discards any `EventQueue` events with `event.epoch < activeEpoch`, and the feeder refills the window under `newEpoch`.

```text
Piano Roll / Staff UI (L5)
  ──▶ Domain Command (L4: 960 PPQN + crisp_notation_core, linked by noteId)
      ──▶ Lookahead Window Compiler (kLookaheadWindowMs) ──▶ ISynthEventBridge (epoch-tagged) ──▶ EventQueue (L2)
          ──▶ FluidSynth render in processAudio() (L3) ──▶ miniaudio / AudioWorklet (L1)
```

### Real-Time Recording & Latency Compensation Loop

When aligning recorded microphone takes back to the `960 PPQN` musical timeline, L4 subtracts round-trip hardware and calibration latency from the latched **playhead timeline frame** (`capturedPlayheadFrame`, latched on the first captured frame alongside hardware `capturedSampleClock`):

```text
alignedSampleFrame = max(0, capturedPlayheadFrame - (outputBufferFrames + inputBufferFrames + calibrationOffsetFrames))
```

```text
Mic Input (L1: pInput / MediaStream)
  ──▶ processAudio() copies f32 frames + latches {capturedPlayheadFrame, capturedSampleClock} (L3)
      ├──▶ CaptureRingBuffer / Web Batched Transfer (L2)
      │       ──▶ Butler Worker: ma_encoder WAV → staging/ → finalize header + SHA-256
      │           ──▶ IRecordingBridge receipt ──▶ lib/storage/: promote cas/<aa>/<sha256>.wav + UPSERT audio_takes
      └──▶ TelemetryQueue peak/RMS waveform blocks ──▶ ITelemetryBridge ──▶ L5 Recording Waveform UI
```

### Playhead & Metering Loop (30–60Hz)

```text
processAudio() pushes TelemetryFrame (playheadSampleFrame, L/R peaks/RMS, underruns)
  ──▶ TelemetryQueue (L2) ──▶ ITelemetryBridge.drainTelemetry() (single drainer in L5; caches latestSnapshot for L4) ──▶ Flutter Playhead Overlay & Meters (L5)
```

---

## 12. Threading & Execution Model (Native vs. Web)

| Execution Context | Native (iOS / Android / Desktop) | Web (`flutter build web --wasm`) | Real-Time Safe |
| :--- | :--- | :--- | :--- |
| **Audio Callback** | `miniaudio` high-priority OS audio thread | Browser `AudioWorkletProcessor` thread (also hosts `FluidSynth` Wasm memory in non-SAB mode; loads `.sf2` only while transport is stopped) | **Yes** (no allocs, locks, or I/O during active rendering) |
| **Butler / Storage Worker** | Dedicated C++ worker thread (`std::thread`) for WAV/SF2 + Dart isolate (`lib/storage/`) for SQLite/CAS | Web Worker (`MessagePort`) owning OPFS `FileSystemSyncAccessHandle`, WAV staging/hashing, & `sqlite3.wasm` VFS | **No** (performs file/OPFS I/O, SQLite, & staging/hashing) |
| **UI / Main Thread** | Flutter UI Isolate (`30–60Hz` telemetry poll) | Browser main thread / WasmGC UI Isolate | **No** |

---

## 13. Planned Repository Layout

```text
muse_grid/
├── ARCHITECTURE.md                  # System architecture specification (this document)
├── database.md                      # SQLite schema & Content-Addressed Storage (CAS) data model
├── interfaces_classes.md            # Cross-layer Dart/C ABI contracts & engine constants
├── requirements.md                  # Project requirements & planned library stack
├── toolchain_and_dependencies.md    # SDKs, build toolchains, Dart/Flutter & C/Wasm dependencies
├── pubspec.yaml                     # Flutter app dependencies (crisp_notation, crisp_notation_core, web, sqlite3, path_provider, ffigen)
├── lib/
│   ├── app/                         # Composition Root (DI, lifecycle, audio bridge & storage adapter wiring)
│   ├── domain/                      # L4: 960 PPQN timeline, noteId sync, crisp_notation_core adapters, storage contracts
│   ├── bridge/
│   │   ├── contracts/               # Pure Dart audio Middle Bridge interfaces + POD models (safe for L4/L5)
│   │   ├── native/                  # Native FFI audio bridge (wired by lib/app/)
│   │   └── web/                     # Web AudioWorklet/MessagePort audio bridge (wired by lib/app/)
│   ├── storage/
│   │   ├── native/                  # Native SQLite FFI + ApplicationSupportDirectory/SAF/UIDocumentPicker adapters
│   │   ├── web/                     # Web sqlite3.wasm + OPFS + quota guard + File/Blob import-export adapters
│   │   └── cloud/                   # [Future] Remote CRUD API & object storage sync adapter
│   └── presentation/                # L5: Staff views, custom Piano Roll Dynamic Grid, transport/recording UI
└── packages/
    └── muse_audio_engine/           # Local FFI + Web plugin (L1–L3) [Planned]
        ├── engine_core/             # Shared C/C++: FluidSynth + SPSC queues + 3-phase cycle
        ├── native/                  # miniaudio duplex HAL + ma_encoder + Dart Build Hooks (native_toolchain_c) / FluidSynth CMake + ffigen
        └── web/                     # Emscripten Wasm build + AudioWorkletProcessor JS glue
```
