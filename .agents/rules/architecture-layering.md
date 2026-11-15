---
trigger: always_on
---

# Architecture Layering Rules — MuseGrid

MuseGrid follows a strict **5-layer + Middle Bridge** architecture separating Pure Dart/Flutter notation and UI from the unified C/C++ + WebAssembly real-time audio engine. Every layer depends **only downward**—never upward.

## 1. The 5-Layer Hierarchy

| Layer | Name | Runtime / Language | Key Directory |
| :--- | :--- | :--- | :--- |
| **—** | Composition Root | Dart | `lib/app/` |
| **5** | Presentation | Flutter (`crisp_notation`, custom Piano Roll) | `lib/presentation/` |
| **4** | Musical & Notation Domain | Pure Dart (`crisp_notation_core`, `960 PPQN`) | `lib/domain/` |
| **Bridge / Storage** | Middle Bridge & Storage Adapters | Dart (`dart:ffi` / `package:web` / `sqlite3` / OPFS) | `lib/bridge/`, `lib/storage/` |
| **3** | Core Audio & Synthesis Engine | C/C++ (`FluidSynth`, 3-phase cycle) | `packages/muse_audio_engine/engine_core/` |
| **2** | Core Real-Time Infrastructure | C/C++ (Lock-free SPSC queues, PODs, clock) | `packages/muse_audio_engine/engine_core/infra/` |
| **1** | Platform Audio HAL | `miniaudio` Duplex (Native) / Web `AudioWorklet` | `packages/muse_audio_engine/{native,web}/` |

## 2. Dependency Rules

- **Directional Dependency:** Layer $N$ may only depend on layers below it ($N-1, N-2, \dots$).
- **No Upward Imports:** Files in Layer $N$ must **never** import packages, headers, or symbols from Layer $N+1$ or higher.
- **Pure Dart Domain Isolation (L4):** `lib/domain/` must remain pure Dart and WasmGC-compatible. Do **not** import `package:flutter`, `dart:io`, `dart:ffi`, or `package:web` inside L4.
- **Presentation Decoupling (L5):** `lib/presentation/` must **never** import `dart:ffi`, C bindings, `package:web` audio worklet internals, `lib/storage/{native,web}/`, or Layers 1–3 directly. All audio/recording calls go through Middle Bridge contracts (`lib/bridge/contracts/`); all score/grid edits and persistence go through L4 (`lib/domain/`).
- **Platform Storage Separation:** `lib/storage/{native,web}/` implements Pure Dart repository interfaces defined in L4 (`lib/domain/`), using platform-specific SQLite/filesystem/OPFS APIs. Neither L4 nor L5 may import `lib/storage/{native,web}/`.
- **POD Bridge Boundary:** Data crossing `lib/bridge/` into the C/C++ or Wasm audio engine must use fixed-size POD structs or typed byte buffers (`Float32List` / `Uint8List`).
- **Composition Root Exception:** Only `lib/app/` may import across all Dart layers to wire platform-specific bridges (`NativeAudioBridge` vs. `WebAudioWorkletBridge`), platform storage adapters (`NativeStorageAdapter` vs. `WebOpfsStorageAdapter`), and inject dependencies.

## 3. Web & Cross-Platform Compatibility

- Use `package:web` and `dart:js_interop` for Web interop so `flutter build web --wasm` remains supported. Never import deprecated `dart:html` or `package:js`.
- Keep all platform-specific filesystem, audio session, and browser worklet handling behind Layer 1 / Bridge adapters.

## 4. Real-Time Safety Boundary

- Real-time audio threads (L1–L3) must never block, allocate, lock, or perform disk/network/UI I/O.
- Cross-thread communication between Dart/UI and the audio callback uses lock-free SPSC queues (`MutationQueue`, `EventQueue`, `CaptureRingBuffer`, `TelemetryQueue`) defined in L2.

## 5. Implementation Workflow

1. Implement and test lower layers (`engine_core` L1–L3 and `lib/domain/` L4) before wiring UI views.
2. Keep Middle Bridge contracts (`lib/bridge/`) segregated by capability (`IAudioLifecycleBridge`, `ITransportBridge`, `ISynthEventBridge`, `IRecordingBridge`, `ITelemetryBridge`).
3. Test each layer independently using mocks or fakes at the Bridge and Domain boundaries.
