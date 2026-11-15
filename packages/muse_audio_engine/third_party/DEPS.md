# Pinned Audio Engine Third-Party Dependencies

All third-party C/C++ dependencies and Emscripten SDK versions for `packages/muse_audio_engine/` are pinned to exact release tags and commit hashes per [toolchain_and_dependencies.md](file:///Users/goldenfung/Documents/muse_grid/toolchain_and_dependencies.md) and installed via:

```sh
dart tool/setup_audio_engine.dart
```

| Dependency | Version / Tag | Commit / Release Ref | License | Integration Method |
| :--- | :--- | :--- | :--- | :--- |
| **FluidSynth** (`libfluidsynth`) | `v2.6.2` | `c3b244ddfd094489a5490beee013c621a504adf2` | LGPL-2.1 *(compliance review required for static iOS & Web distribution)* | CMake `FetchContent` (static, thread-free SF2-only core) |
| **miniaudio** | `0.11.26` | `877ea4a7c2601c7b0f2a44e83dfac42e6470fea6` | MIT-0 / Unlicense | CMake `FetchContent` (Native only) |
| **PicoSHA2** | `v1.0.1` | `161cb3fc4170fa7a3eca9e582cebd27cc4d1fe29` | MIT | CMake `FetchContent` |
| **Catch2** | `v3.16.1` | `08092139210881f01a34e60c5f2fd6afa0ea4024` | BSL-1.0 | CMake `FetchContent` (`BUILD_TESTING` only) |
| **Emscripten SDK (`emsdk`)** | `7.0.0` | `6afbd83493d647051772d491124187d4e9a0cda9` | MIT / NCSA | Automated by `tool/setup_audio_engine.dart` into `packages/muse_audio_engine/.emsdk/` (or `$EMSDK`) |
