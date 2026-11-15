# SDK, Build Toolchains & Library Management — MuseGrid

This document defines the canonical SDKs, cross-platform build toolchains, Dart/Flutter packages, WebAssembly assets, and C/C++ audio engine dependencies for **MuseGrid**. It assumes a **clean developer workstation (Linux, Windows, or macOS) with zero pre-installed C/C++ or Wasm tools** and **reproducible GitHub Actions CI builds** without macOS-only tools such as `brew`.

Related specifications:
- System architecture: [ARCHITECTURE.md](file:///Users/goldenfung/Documents/muse_grid/ARCHITECTURE.md)
- Requirements & stack rationale: [requirements.md](file:///Users/goldenfung/Documents/muse_grid/requirements.md)
- SQLite & CAS persistence: [database.md](file:///Users/goldenfung/Documents/muse_grid/database.md)
- Cross-layer APIs & C ABI: [interfaces_classes.md](file:///Users/goldenfung/Documents/muse_grid/interfaces_classes.md)

---

## 1. Host SDKs & Build Toolchains

### 1.1 Baseline Verified SDKs

| Component | Baseline / Constraint | Management & CI |
| :--- | :--- | :--- |
| **Flutter SDK** | `3.50.0` (stable channel) | Local: `fvm` or official Flutter archive; CI: `subosito/flutter-action` |
| **Dart SDK** | `^3.14.0` (`3.14.0` bundled with Flutter `3.50.0`, enforced in [pubspec.yaml](file:///Users/goldenfung/Documents/muse_grid/pubspec.yaml#L22)) | Bundled with Flutter |

### 1.2 Cross-Platform C/C++ & Wasm Host Tools (Current vs. Planned Audio Engine)

For the **current Dart/Flutter/SQLite/Web stack** (`pubspec.yaml`), **only the Flutter SDK** (plus **Xcode** on macOS for Apple targets, or **Android SDK** when targeting Android) is required:
- `sqlite3` (`3.9.1`) uses Dart Build Hooks (`hooks` + `native_toolchain_c`) to fetch **prebuilt** native binaries by default (falling back to `CBuilder` direct compiler invocations only if explicitly configured to build from source) and uses [web/sqlite3.wasm](file:///Users/goldenfung/Documents/muse_grid/web/sqlite3.wasm) on Web.
- `flutter build web --wasm` compiles Dart via the bundled `dart2wasm` toolchain without `emsdk`, `CMake`, or `Ninja`.

When implementing the **planned C/C++ & Wasm audio engine (`packages/muse_audio_engine/`)**, no developer or CI runner is assumed to have system C/C++ tools pre-installed beyond platform SDKs (**never depend on `brew install`**). **Ninja is not required**: Dart Build Hooks (`native_toolchain_c`) invoke platform compilers directly for native code, and where CMake is used (upstream `FluidSynth`, Emscripten Wasm, or offline C++ tests), standard generators (`Unix Makefiles` via `make`, `Xcode`, or Visual Studio `MSBuild`) work without Ninja.

| Tool | Scope & Purpose | Clean Machine Install (Linux / Windows / macOS) | GitHub Actions Action / Setup |
| :--- | :--- | :--- | :--- |
| **Git** | Source checkout, submodules, CMake `FetchContent` | Official installer (`git-scm.com`) | Pre-installed on GitHub-hosted runners |
| **CMake** (`>= 3.24`) | *(Planned L1–L3)* Builds upstream `FluidSynth` static lib, Emscripten Wasm (`emcmake cmake`), and offline C++ tests (`Unix Makefiles` / `Xcode` / `MSBuild`; **Ninja is optional**) | Official binaries (`cmake.org`) | `lukka/get-cmake` (optional until `packages/muse_audio_engine/` exists) |
| **Python 3** | *(Planned Web Wasm)* Required by `emsdk` | Official installer (`python.org`; pre-installed on macOS/Ubuntu runners) | `actions/setup-python` |
| **Emscripten SDK (`emsdk`)** | *(Planned Web Wasm)* Compiles L2–L3 `engine_core` + `FluidSynth` into `muse_audio_engine.wasm` for `AudioWorklet` (pinned `7.0.0`) | Automated cross-platform via `dart run tool/setup_audio_engine.dart` (installs into `packages/muse_audio_engine/.emsdk/` or `$EMSDK` on Windows/Linux/macOS) | `mymindstorm/setup-emsdk` (`7.0.0` + runner cache) |
| **LLVM / `libclang`** | *(Dev codegen only)* Parses `muse_engine_c_api.h` when regenerating Dart FFI bindings (`dart run tool/ffigen.dart`) | **macOS:** Uses Xcode's bundled `libclang.dylib` automatically (no separate LLVM needed). **Linux:** `libclang-dev`. **Windows:** Official LLVM release (`releases.llvm.org`). | Only needed if a CI job regenerates `ffigen` bindings |

### 1.3 Target Platform Compilers & Native SDKs

| Target Platform | Host OSes Supported | Required Compiler / SDK | CI Runner & Setup |
| :--- | :--- | :--- | :--- |
| **Web (Flutter WasmGC + Planned `AudioWorklet` Wasm)** | Linux, Windows, macOS | **Current:** `Flutter` (`--wasm` / `dart2wasm` only). **Planned L2–L3 Wasm:** `emsdk` + `CMake` + `make` (`Unix Makefiles`). | `ubuntu-latest` (+ `mymindstorm/setup-emsdk` once `muse_audio_engine` is added) |
| **Android** | Linux, Windows, macOS | Android SDK Command-line Tools + **pinned Android NDK** (`arm64-v8a`, `armeabi-v7a`, `x86_64`; links `aaudio`, `opensles`, `log`, `m` via `native_toolchain_c` or NDK toolchain) | `ubuntu-latest` + `android-actions/setup-android` |
| **Linux** | Linux | `clang` or `gcc`/`g++` + `make` + ALSA headers (`libasound2-dev`), `pthread`, `dl`, `m` | `ubuntu-latest` (`sudo apt-get install -y libasound2-dev`) |
| **Windows** | Windows | MSVC Build Tools (C++ workload / Visual Studio MSBuild) + Windows SDK (`ole32`, `winmm`, `avrt`) | `windows-latest` + `ilammy/msvc-dev-cmd` |
| **iOS & macOS** | macOS only | **Xcode** + iOS/macOS SDKs (`AudioToolbox`, `CoreAudio`, `AVFoundation`, `AudioUnit`; Swift Package Manager enabled for plugins) | `macos-latest` + `maxim-lobanov/setup-xcode` |

---

## 2. Dart & Flutter Package Management (`pubspec.yaml`)

### 2.1 Active Dependencies & Compatibility Matrix

All packages below are declared in [pubspec.yaml](file:///Users/goldenfung/Documents/muse_grid/pubspec.yaml), locked in [pubspec.lock](file:///Users/goldenfung/Documents/muse_grid/pubspec.lock), and verified compatible with `Flutter 3.50.0`, `Dart 3.14.0`, and `flutter build web --wasm`:

| Package | Constraint (Locked) | Layer / Scope | Wasm-Ready | Notes |
| :--- | :--- | :--- | :--- | :--- |
| `crisp_notation_core` | `^0.14.0` (`0.14.0`) | **L4 Domain** (Pure Dart) | Yes | Zero external deps; includes MusicXML & `.mxl` ZIP container support |
| `crisp_notation` | `^0.14.0` (`0.14.0`) | **L5 UI** (Flutter) | Yes | Standard 5-line staff rendering + Bravura SMuFL font |
| `sqlite3` | `^3.9.1` (`3.9.1`) | **`lib/storage/`** | Native Hooks + Web Wasm | Downloads prebuilt native `libsqlite3` via Dart Build Hooks (`hooks` `2.2.0`, `code_assets` `2.2.0`, `native_toolchain_c` `0.19.6`) with `CBuilder` source fallback; uses `package:sqlite3/wasm.dart` (`SimpleOpfsFileSystem`, `WasmVfs`, `IndexedDbFileSystem`) on Web |
| `web` | `^1.1.2` (`1.1.2`) | **`lib/bridge/web/`**, **`lib/storage/web/`** | Yes | Paired with `dart:js_interop` for `AudioWorklet`, OPFS, `MessagePort` |
| `path_provider` | `^2.1.6` (`2.1.6`) | **`lib/storage/native/`** | Native only | Never import outside `lib/storage/native/` (not supported on Web) |
| `path` | `^1.9.1` (`1.9.1`) | Shared Dart / Storage | Yes | Cross-platform path handling |
| `crypto` | `^3.0.8` (`3.0.8`) | Storage / CAS | Yes | SHA-256 digest computation for `cas/<aa>/<sha256>.<ext>` |
| `uuid` | `^4.6.0` (`4.6.0`) | L4 Domain / Storage | Yes | Generates `UUIDv7` primary keys (`Uuid.v7()`) |
| `ffi` | `^2.2.0` (`2.2.0`) | **`lib/bridge/native/`** | Native only | `dart:ffi` memory/UTF-8 helpers; keep quarantined behind `lib/app/` conditional imports |
| `permission_handler` | `^13.0.2` (`13.0.2`) | **`lib/app/`** / Platform guard | Yes | Runtime `RECORD_AUDIO` check on Android/iOS/Windows/Web (does not target macOS/Linux) |
| `file_picker` | `^13.3.3` (`13.3.3`) | **`lib/storage/`** / UI import | Yes | Copy-on-Import across all 6 platforms (SAF, iOS Document Picker, desktop, Web) |
| `share_plus` | `^13.3.1` (`13.3.1`) | **`lib/storage/`** / UI export | Compiles in `--wasm` | Stage-on-Export OS share/save sheet across all 6 platforms |
| `ffigen` *(dev)* | `^23.0.0` (`23.0.0`) | Codegen (`lib/bridge/native/`) | Dev tool | Generates FFI bindings from `muse_engine_c_api.h` via programmatic `FfiGenerator` script (`dart run tool/ffigen.dart`; YAML `dart run ffigen` is deprecated in `23.0.0`); shares `hooks`/`code_assets`/`native_toolchain_c` constraints with `sqlite3` `3.9.1` |
| `material_ui` | `^1.1.0` (`1.11.0`) | **L5 UI** (Template) | Yes | Flutter template UI library (imported in `lib/main.dart`) |
| `cupertino_icons` | `^1.0.8` (`1.0.9`) | **L5 UI** (Template) | Yes | Kept on `^1.0.x` to stay compatible with Flutter template icon references |
| `flutter_lints` *(dev)* | `^6.0.0` (`6.0.0`) | Static Analysis | Dev tool | Activated via [analysis_options.yaml](file:///Users/goldenfung/Documents/muse_grid/analysis_options.yaml) |

### 2.2 Layer Isolation & Lockfile Rules

1. **L4 Pure Dart (`lib/domain/`):** May only import `crisp_notation_core`, `uuid`, `path`, `crypto`, and `lib/bridge/contracts/`. Never import `flutter`, `dart:io`, `dart:ffi`, `package:web`, `path_provider`, or `sqlite3`.
2. **Platform Quarantine (`lib/bridge/native/`, `lib/storage/native/`):** `dart:ffi`, `package:ffi`, `package:sqlite3/sqlite3.dart`, and `package:path_provider` must only be wired in [lib/app/](file:///Users/goldenfung/Documents/muse_grid/ARCHITECTURE.md#L200) via conditional imports (`if (dart.library.js_interop)` / `if (dart.library.io)`) so `flutter build web --wasm` never pulls `dart:ffi` or `dart:io`.
3. **Lockfile Policy:** Commit [pubspec.lock](file:///Users/goldenfung/Documents/muse_grid/pubspec.lock) to source control so CI and all developers resolve identical transitive dependencies.

---

## 3. Web Binary Assets (`web/`)

### 3.1 `sqlite3.wasm` (Active)

- **File:** [web/sqlite3.wasm](file:///Users/goldenfung/Documents/muse_grid/web/sqlite3.wasm) (`758,836` bytes, MVP WebAssembly binary).
- **Source & Version-Lock Invariant:** Downloaded from the `simolus3/sqlite3.dart` GitHub release matching the exact `sqlite3` version in [pubspec.lock](file:///Users/goldenfung/Documents/muse_grid/pubspec.lock) (`sqlite3-3.9.1`).
  - `package:sqlite3/wasm.dart` expects package-specific Wasm host imports—generic `sqlite3.wasm` builds (e.g., `sql.js`) will not work, and upgrading `sqlite3` in `pubspec.yaml` **must** update `web/sqlite3.wasm` from the matching release tag.
- **Verification:** `flutter build web --wasm` copies [web/sqlite3.wasm](file:///Users/goldenfung/Documents/muse_grid/web/sqlite3.wasm) directly into `build/web/sqlite3.wasm`.

### 3.2 `muse_audio_engine.wasm` & `AudioWorklet` Assets *(Planned)*

- Compiled from `packages/muse_audio_engine/` using pinned `emsdk` and placed in `web/` alongside the `AudioWorkletProcessor` JS loader.
- **Web Hosting Headers:** Serve over HTTPS (or `http://localhost` in dev). Enabling `SharedArrayBuffer` mode requires:
  - `Cross-Origin-Opener-Policy: same-origin`
  - `Cross-Origin-Embedder-Policy: require-corp`
  - When those headers are absent, the Web audio bridge falls back explicitly to single-threaded `AudioWorklet` + `MessagePort` batch transfer (`kWebCaptureBatchQuanta`).

---

## 4. C/C++ & Wasm Audio Engine Libraries (`packages/muse_audio_engine/`)

All third-party C/C++ sources are **pinned by commit hash** in [CMakeLists.txt](file:///Users/goldenfung/Documents/muse_grid/packages/muse_audio_engine/CMakeLists.txt) (see [DEPS.md](file:///Users/goldenfung/Documents/muse_grid/packages/muse_audio_engine/third_party/DEPS.md)) and installed/verified cross-platform (Windows, Linux, macOS) via `dart run tool/setup_audio_engine.dart`. **Never rely on OS-level library installs** (`apt install libfluidsynth-dev`, `brew install fluid-synth`, etc.).

| Library | Scope | Pinning Strategy | Build Configuration & Compliance |
| :--- | :--- | :--- | :--- |
| **`FluidSynth`** (`libfluidsynth`, `v2.6.2`) | L3 Synth (Native + Web Wasm) | CMake `FetchContent` (`c3b244ddfd094489a5490beee013c621a504adf2`) | Static, thread-free SF2-only core: `osal=cpp11` (Native) / `osal=embedded` (Emscripten Wasm), `enable-floats=ON`, `enable-threads=OFF`, `enable-libsndfile=OFF`, `enable-native-dls=OFF`, `enable-signalsmith=OFF`, all OS audio/MIDI drivers disabled. Renders via `fluid_synth_write_float()`. **Requires LGPL-2.1 compliance review for static linking on iOS & Web.** |
| **`miniaudio`** (`0.11.26`) | L1 Native HAL + L3 Native Butler | CMake `FetchContent` (`877ea4a7c2601c7b0f2a44e83dfac42e6470fea6`) | Native only (`NOT EMSCRIPTEN`). Full-duplex (`ma_device_type_duplex`), iOS `AVAudioSession` (`ma_ios_session_category_play_and_record`), Android AAudio/OpenSL ES, WAV capture (`ma_encoder` / `ma_encoding_format_wav`), and take resampling (`ma_data_converter`). |
| **`PicoSHA2`** (`v1.0.1`) | L3 Native Butler | CMake `FetchContent` (`161cb3fc4170fa7a3eca9e582cebd27cc4d1fe29`, MIT) | Header-only C++ SHA-256 computing lowercase 64-char hex digests sequentially over finalized staging `.wav` files (`FinalizedCaptureReceipt.sha256_hex[65]`) with zero OpenSSL dependency. |
| **`Catch2`** (`v3.16.1`, *dev/CI*) | L2–L3 offline tests | CMake `FetchContent` (`08092139210881f01a34e60c5f2fd6afa0ea4024`, `BUILD_TESTING`) | Tests SPSC ring buffers, POD sizes/trivially-copyable `static_assert`s, epoch gating, WAV header patching, and offline `FluidSynth` output without audio hardware. |

---

## 5. Explicitly Excluded Libraries

Do **not** add any of the following (per [ARCHITECTURE.md](file:///Users/goldenfung/Documents/muse_grid/ARCHITECTURE.md) and [requirements.md](file:///Users/goldenfung/Documents/muse_grid/requirements.md)):

- **`sqlite3_flutter_libs`** (`0.6.0+eol`) and **`drift_flutter`** (still depends on EOL `sqlite3_flutter_libs`) — replaced by `sqlite3` `3.x` native Build Hooks.
- **`soundfont_kit`**, **`flutter_soloud`**, **`flutter_recorder`** — rejected to preserve a single audio session owner and sample-locked duplex clock.
- **`libsndfile`**, **Ogg-Vorbis**, **`libinstpatch`** — SF3 is out of scope; `FluidSynth` is SF2-only.
- **Opus / FLAC encoders** and **FFT / audio-analysis libraries** — recordings are raw WAV only; spectral analysis is deferred.
- **`.zip` / archive packers for `.musegrid` project bundles** — project storage uses SQLite + CAS (and `.mxl` compressed MusicXML is handled internally by `crisp_notation_core`).
- **`dart:html`** and **`package:js`** — forbidden by `flutter build web --wasm`; use `package:web` + `dart:js_interop`.

---

## 6. Platform Manifest & Permission Prerequisites *(Pending Audio Engine Integration)*

| Platform | File | Required Entry | Status |
| :--- | :--- | :--- | :--- |
| **iOS** | [ios/Runner/Info.plist](file:///Users/goldenfung/Documents/muse_grid/ios/Runner/Info.plist) | `NSMicrophoneUsageDescription` | Pending |
| **Android** | [android/app/src/main/AndroidManifest.xml](file:///Users/goldenfung/Documents/muse_grid/android/app/src/main/AndroidManifest.xml) | `<uses-permission android:name="android.permission.RECORD_AUDIO" />` | Pending |

---

## 7. GitHub Actions CI & Upgrade Workflow

### 7.1 Build Workflow

The [GitHub Actions build workflow](../.github/workflows/build.yml) runs
`flutter analyze` and `flutter test`, then builds release apps for macOS,
Windows, Linux, and Android. Each build bootstraps the native audio engine;
Android produces an APK for the supported ABIs. Build outputs are uploaded as
workflow artifacts for seven days.

### 7.2 Dependency Upgrade Checklist

1. **Dart/Flutter packages:** Run `flutter pub upgrade` (or targeted `flutter pub add`), review `pubspec.lock` diffs, and keep `path_provider`/`ffi` quarantined from Web imports.
2. **When `sqlite3` updates:** Download the matching `sqlite3.wasm` from `simolus3/sqlite3.dart` release tag `sqlite3-<version>` into [web/sqlite3.wasm](file:///Users/goldenfung/Documents/muse_grid/web/sqlite3.wasm).
3. **When `muse_engine_c_api.h` changes:** Regenerate `lib/bridge/native/` bindings via `dart run tool/ffigen.dart` (`FfiGenerator` API) and verify both Native and Emscripten Wasm builds.
4. **Verification Gate:** Every dependency or toolchain update must pass:
   ```sh
   flutter analyze
   flutter test
   flutter build web --wasm
   ```
