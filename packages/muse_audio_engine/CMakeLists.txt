cmake_minimum_required(VERSION 3.24)
project(muse_audio_engine LANGUAGES C CXX)

set(CMAKE_C_STANDARD 11)
set(CMAKE_C_STANDARD_REQUIRED ON)
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

include(FetchContent)
include(CTest)

# ---------------------------------------------------------------------------
# Pinned Third-Party Dependencies (toolchain_and_dependencies.md §4)
# ---------------------------------------------------------------------------

# 1. FluidSynth (v2.6.2, LGPL-2.1) — static, thread-free SF2-only core
set(BUILD_SHARED_LIBS OFF CACHE BOOL "" FORCE)
set(enable-floats ON CACHE BOOL "" FORCE)
set(enable-threads OFF CACHE BOOL "" FORCE)
set(enable-libsndfile OFF CACHE BOOL "" FORCE)
set(enable-native-dls OFF CACHE BOOL "" FORCE)
set(enable-signalsmith OFF CACHE BOOL "" FORCE)
set(enable-openmp OFF CACHE BOOL "" FORCE)
set(enable-network OFF CACHE BOOL "" FORCE)
set(enable-ipv6 OFF CACHE BOOL "" FORCE)
set(enable-aufile OFF CACHE BOOL "" FORCE)
set(enable-alsa OFF CACHE BOOL "" FORCE)
set(enable-dbus OFF CACHE BOOL "" FORCE)
set(enable-jack OFF CACHE BOOL "" FORCE)
set(enable-ladspa OFF CACHE BOOL "" FORCE)
set(enable-midishare OFF CACHE BOOL "" FORCE)
set(enable-opensles OFF CACHE BOOL "" FORCE)
set(enable-oboe OFF CACHE BOOL "" FORCE)
set(enable-oss OFF CACHE BOOL "" FORCE)
set(enable-dsound OFF CACHE BOOL "" FORCE)
set(enable-wasapi OFF CACHE BOOL "" FORCE)
set(enable-waveout OFF CACHE BOOL "" FORCE)
set(enable-winmidi OFF CACHE BOOL "" FORCE)
set(enable-sdl3 OFF CACHE BOOL "" FORCE)
set(enable-pulseaudio OFF CACHE BOOL "" FORCE)
set(enable-pipewire OFF CACHE BOOL "" FORCE)
set(enable-portaudio OFF CACHE BOOL "" FORCE)
set(enable-readline OFF CACHE BOOL "" FORCE)
set(enable-systemd OFF CACHE BOOL "" FORCE)
set(enable-coreaudio OFF CACHE BOOL "" FORCE)
set(enable-coremidi OFF CACHE BOOL "" FORCE)
set(enable-framework OFF CACHE BOOL "" FORCE)
if(CMAKE_SYSTEM_NAME STREQUAL "iOS")
  # Upstream FluidSynth's CLI executable target omits BUNDLE DESTINATION when
  # CMake's iOS platform file sets CMAKE_MACOSX_BUNDLE as a normal variable.
  set(CMAKE_MACOSX_BUNDLE OFF)
endif()

if(EMSCRIPTEN)
  set(osal "embedded" CACHE STRING "" FORCE)
else()
  set(osal "cpp11" CACHE STRING "" FORCE)
endif()

FetchContent_Declare(
  fluidsynth
  GIT_REPOSITORY https://github.com/FluidSynth/fluidsynth.git
  GIT_TAG        c3b244ddfd094489a5490beee013c621a504adf2 # v2.6.2
  GIT_SHALLOW    TRUE
)
set(_MUSE_IN_FLUIDSYNTH_FETCH ON)
if(NOT DEFINED _MUSE_ADD_SUBDIRECTORY_WRAPPED)
  set(_MUSE_ADD_SUBDIRECTORY_WRAPPED TRUE)
  macro(add_subdirectory dir)
    if(_MUSE_IN_FLUIDSYNTH_FETCH AND
       "${CMAKE_CURRENT_SOURCE_DIR}" STREQUAL "${fluidsynth_SOURCE_DIR}" AND
       ("${dir}" STREQUAL "test" OR "${dir}" STREQUAL "doc"))
      # Skip upstream FluidSynth test and doc subdirectories in MuseGrid superbuild.
    else()
      _add_subdirectory(${ARGV})
    endif()
  endmacro()
endif()

FetchContent_MakeAvailable(fluidsynth)
set(_MUSE_IN_FLUIDSYNTH_FETCH OFF)

# FluidSynth v2.6.2 resets CMAKE_CXX_STANDARD to 11 when osal=embedded, yet
# src/drivers/fluid_audio_convert.h uses C++17 std::clamp.
if(TARGET libfluidsynth-OBJ)
  target_compile_features(libfluidsynth-OBJ PUBLIC cxx_std_17)
endif()
if(TARGET libfluidsynth)
  target_compile_features(libfluidsynth PUBLIC cxx_std_17)
endif()

# 2. PicoSHA2 (v1.0.1, MIT) — header-only SHA-256 without OpenSSL
set(PICOSHA2_TEST OFF CACHE BOOL "" FORCE)
set(PICOSHA2_EXAMPLE OFF CACHE BOOL "" FORCE)
FetchContent_Declare(
  picosha2
  GIT_REPOSITORY https://github.com/okdshin/PicoSHA2.git
  GIT_TAG        161cb3fc4170fa7a3eca9e582cebd27cc4d1fe29 # v1.0.1
  GIT_SHALLOW    TRUE
)
FetchContent_MakeAvailable(picosha2)

# 3. miniaudio (0.11.26, MIT-0 / Unlicense) — Native HAL & WAV encoder only
if(NOT EMSCRIPTEN)
  set(MINIAUDIO_BUILD_EXAMPLES OFF CACHE BOOL "" FORCE)
  set(MINIAUDIO_BUILD_TESTS OFF CACHE BOOL "" FORCE)
  set(MINIAUDIO_BUILD_TOOLS OFF CACHE BOOL "" FORCE)
  set(MINIAUDIO_NO_EXTRA_NODES ON CACHE BOOL "" FORCE)
  set(MINIAUDIO_NO_LIBVORBIS ON CACHE BOOL "" FORCE)
  set(MINIAUDIO_NO_LIBOPUS ON CACHE BOOL "" FORCE)
  FetchContent_Declare(
    miniaudio
    GIT_REPOSITORY https://github.com/mackron/miniaudio.git
    GIT_TAG        877ea4a7c2601c7b0f2a44e83dfac42e6470fea6 # 0.11.26
    GIT_SHALLOW    TRUE
  )
  FetchContent_MakeAvailable(miniaudio)
endif()

# ---------------------------------------------------------------------------
# Phase 2 Core Audio Engine Static Library (Native + Emscripten Wasm)
# ---------------------------------------------------------------------------
add_library(muse_audio_engine_core STATIC
  engine_core/audio_engine_core.cpp
  engine_core/muse_engine_c_api.cpp
)
target_include_directories(muse_audio_engine_core PUBLIC
  ${CMAKE_CURRENT_SOURCE_DIR}/engine_core
)
target_link_libraries(muse_audio_engine_core PUBLIC
  libfluidsynth
  picosha2
)
if(NOT EMSCRIPTEN)
  target_sources(muse_audio_engine_core PRIVATE
    engine_core/butler_worker.cpp
    native/miniaudio_duplex_hal.cpp
  )
  target_include_directories(muse_audio_engine_core PUBLIC
    ${CMAKE_CURRENT_SOURCE_DIR}/native
  )
  target_link_libraries(muse_audio_engine_core PUBLIC
    miniaudio
  )
  if(APPLE)
    target_link_libraries(muse_audio_engine_core PUBLIC
      "-framework AudioToolbox"
      "-framework CoreAudio"
      "-framework CoreFoundation"
    )
  elseif(ANDROID)
    target_link_libraries(muse_audio_engine_core PUBLIC log m dl)
  elseif(UNIX)
    target_link_libraries(muse_audio_engine_core PUBLIC dl m pthread)
  endif()
endif()
if(MSVC)
  target_compile_options(muse_audio_engine_core PRIVATE /W4)
else()
  target_compile_options(muse_audio_engine_core PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ---------------------------------------------------------------------------
# Offline C++ Dependency & Build-Spike Verification Tests (Native)
# ---------------------------------------------------------------------------
if(BUILD_TESTING AND NOT EMSCRIPTEN)
  FetchContent_Declare(
    Catch2
    GIT_REPOSITORY https://github.com/catchorg/Catch2.git
    GIT_TAG        08092139210881f01a34e60c5f2fd6afa0ea4024 # v3.16.1
    GIT_SHALLOW    TRUE
  )
  FetchContent_MakeAvailable(Catch2)

  add_executable(muse_engine_deps_smoke_test
    tests/engine_deps_smoke_test.cpp
  )
  target_link_libraries(muse_engine_deps_smoke_test PRIVATE
    libfluidsynth
    miniaudio
    picosha2
    Catch2::Catch2WithMain
  )

  if(APPLE)
    target_link_libraries(muse_engine_deps_smoke_test PRIVATE
      "-framework AudioToolbox"
      "-framework CoreAudio"
      "-framework CoreFoundation"
    )
  elseif(UNIX)
    target_link_libraries(muse_engine_deps_smoke_test PRIVATE dl m pthread)
  endif()

  include(Catch)
  catch_discover_tests(muse_engine_deps_smoke_test
    TEST_PREFIX "muse."
  )

  add_executable(muse_spsc_and_pods_test
    tests/spsc_and_pods_test.cpp
  )
  target_link_libraries(muse_spsc_and_pods_test PRIVATE
    muse_audio_engine_core
    Catch2::Catch2WithMain
  )
  if(MSVC)
    target_compile_options(muse_spsc_and_pods_test PRIVATE /W4)
  else()
    target_compile_options(muse_spsc_and_pods_test PRIVATE -Wall -Wextra -Wpedantic)
  endif()
  catch_discover_tests(muse_spsc_and_pods_test
    TEST_PREFIX "muse."
  )

  add_executable(muse_engine_cycle_test
    tests/engine_cycle_test.cpp
  )
  target_link_libraries(muse_engine_cycle_test PRIVATE
    muse_audio_engine_core
    Catch2::Catch2WithMain
  )
  if(MSVC)
    target_compile_options(muse_engine_cycle_test PRIVATE /W4)
  else()
    target_compile_options(muse_engine_cycle_test PRIVATE -Wall -Wextra -Wpedantic)
  endif()
  catch_discover_tests(muse_engine_cycle_test
    TEST_PREFIX "muse."
  )

  add_executable(muse_butler_worker_test
    tests/butler_worker_test.cpp
  )
  target_link_libraries(muse_butler_worker_test PRIVATE
    muse_audio_engine_core
    Catch2::Catch2WithMain
  )
  if(MSVC)
    target_compile_options(muse_butler_worker_test PRIVATE /W4)
  else()
    target_compile_options(muse_butler_worker_test PRIVATE -Wall -Wextra -Wpedantic)
  endif()
  catch_discover_tests(muse_butler_worker_test
    TEST_PREFIX "muse."
  )

  add_executable(muse_c_api_integration_test
    tests/c_api_integration_test.cpp
  )
  target_link_libraries(muse_c_api_integration_test PRIVATE
    muse_audio_engine_core
    Catch2::Catch2WithMain
  )
  if(MSVC)
    target_compile_options(muse_c_api_integration_test PRIVATE /W4)
  else()
    target_compile_options(muse_c_api_integration_test PRIVATE -Wall -Wextra -Wpedantic)
  endif()
  catch_discover_tests(muse_c_api_integration_test
    TEST_PREFIX "muse."
  )

  add_executable(muse_miniaudio_duplex_hal_test
    tests/miniaudio_duplex_hal_test.cpp
  )
  target_link_libraries(muse_miniaudio_duplex_hal_test PRIVATE
    muse_audio_engine_core
    Catch2::Catch2WithMain
  )
  if(MSVC)
    target_compile_options(muse_miniaudio_duplex_hal_test PRIVATE /W4)
  else()
    target_compile_options(muse_miniaudio_duplex_hal_test PRIVATE -Wall -Wextra -Wpedantic)
  endif()
  catch_discover_tests(muse_miniaudio_duplex_hal_test
    TEST_PREFIX "muse."
  )
endif()

# ---------------------------------------------------------------------------
# Phase 3 Web AudioWorklet + Emscripten Wasm Glue Target
# ---------------------------------------------------------------------------
if(EMSCRIPTEN)
  add_executable(muse_audio_engine
    web/wasm_worklet_bindings.cpp
  )
  target_link_libraries(muse_audio_engine PRIVATE
    muse_audio_engine_core
  )
  target_compile_options(muse_audio_engine PRIVATE
    -Wall -Wextra -Wpedantic
  )
  set_target_properties(muse_audio_engine PROPERTIES
    SUFFIX ".js"
  )
  target_link_options(muse_audio_engine PRIVATE
    "-sMODULARIZE=1"
    "-sEXPORT_ES6=1"
    "-sEXPORT_NAME=createMuseAudioEngineModule"
    "-sALLOW_MEMORY_GROWTH=1"
    "-sMAXIMUM_MEMORY=268435456"
    "-sENVIRONMENT=worker,shell"
    "-sEXPORTED_RUNTIME_METHODS=HEAPF32,HEAPU8,UTF8ToString,stringToUTF8,lengthBytesUTF8"
    "-sEXPORTED_FUNCTIONS=_muse_wasm_create,_muse_wasm_destroy,_muse_wasm_input_scratch_ptr,_muse_wasm_output_scratch_ptr,_muse_wasm_capture_drain_scratch_ptr,_muse_wasm_capture_clock_ptr,_muse_wasm_event_scratch_ptr,_muse_wasm_take_pcm_scratch_ptr,_muse_wasm_alloc_bytes,_muse_wasm_free_bytes,_muse_wasm_process_quantum,_muse_wasm_drain_capture,_muse_wasm_push_mutation,_muse_wasm_push_single_event,_muse_wasm_load_sf2_bytes,_muse_wasm_preset_bank,_muse_wasm_preset_program,_muse_wasm_preset_name,_muse_wasm_unload_sf2,_muse_wasm_register_active_take,_muse_wasm_push_take_pcm,_muse_wasm_clear_active_takes,_muse_wasm_prepare_capture,_muse_wasm_start_capture,_muse_wasm_captured_playhead_frame_f64,_muse_wasm_did_capture_overflow,_muse_wasm_drain_telemetry,_muse_wasm_telemetry_playhead_f64,_muse_wasm_telemetry_epoch_f64,_muse_wasm_telemetry_meter_f32,_muse_wasm_telemetry_flags_u32,_malloc,_free"
  )
endif()
