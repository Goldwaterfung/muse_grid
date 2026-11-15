#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_floating_point.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <vector>

#include <miniaudio.h>
#include <picosha2.h>

#include "hal_registry.h"
#include "muse_engine_c_api.h"

namespace {

struct EngineGuard {
  MuseEngineHandle handle = nullptr;
  ~EngineGuard() {
    if (handle != nullptr) {
      muse_engine_destroy(handle);
    }
  }
};

struct HalRegistryResetGuard {
  ~HalRegistryResetGuard() {
    muse_engine_register_platform_hal(nullptr, nullptr);
  }
};

struct TempFileGuard {
  std::filesystem::path path;
  ~TempFileGuard() {
    std::error_code ec;
    std::filesystem::remove(path, ec);
  }
};

struct MockHalState {
  int init_calls = 0;
  int start_calls = 0;
  int stop_calls = 0;
  int dispose_calls = 0;
  bool fail_init = false;
  bool fail_start = false;
  MuseHardwareConfig config{};
  void* last_user_data = nullptr;
  MuseAudioProcessCallback last_callback = nullptr;
};

MockHalState* g_mock_hal_state = nullptr;

MuseStatus mockHalInit(
    void* user_data,
    MuseAudioProcessCallback callback,
    MuseHardwareConfig* out_config) {
  if (g_mock_hal_state == nullptr || out_config == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  ++g_mock_hal_state->init_calls;
  if (g_mock_hal_state->fail_init) {
    return MUSE_ERR_DEVICE_INIT;
  }
  g_mock_hal_state->last_user_data = user_data;
  g_mock_hal_state->last_callback = callback;
  *out_config = g_mock_hal_state->config;
  return MUSE_OK;
}

MuseStatus mockHalStart(void* hal_handle) {
  auto* state = static_cast<MockHalState*>(hal_handle);
  if (state == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  ++state->start_calls;
  return state->fail_start ? MUSE_ERR_DEVICE_INIT : MUSE_OK;
}

MuseStatus mockHalStop(void* hal_handle) {
  auto* state = static_cast<MockHalState*>(hal_handle);
  if (state == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  ++state->stop_calls;
  return MUSE_OK;
}

void mockHalDispose(void* hal_handle) {
  auto* state = static_cast<MockHalState*>(hal_handle);
  if (state != nullptr) {
    ++state->dispose_calls;
  }
}

MuseHardwareConfig stereoTestConfig(uint32_t sample_rate, uint32_t in_ch) {
  MuseHardwareConfig cfg{};
  cfg.sample_rate = sample_rate;
  cfg.input_channels = in_ch;
  cfg.output_channels = 2;
  cfg.input_buffer_frames = 256;
  cfg.output_buffer_frames = 256;
  std::snprintf(cfg.device_fingerprint, sizeof(cfg.device_fingerprint),
                "c-api-integration-device");
  return cfg;
}

void appendFourCc(std::vector<uint8_t>& out, const char* id) {
  out.insert(out.end(), id, id + 4);
}

void appendU16(std::vector<uint8_t>& out, uint16_t v) {
  out.push_back(static_cast<uint8_t>(v & 0xFFu));
  out.push_back(static_cast<uint8_t>((v >> 8) & 0xFFu));
}

void appendU32(std::vector<uint8_t>& out, uint32_t v) {
  out.push_back(static_cast<uint8_t>(v & 0xFFu));
  out.push_back(static_cast<uint8_t>((v >> 8) & 0xFFu));
  out.push_back(static_cast<uint8_t>((v >> 16) & 0xFFu));
  out.push_back(static_cast<uint8_t>((v >> 24) & 0xFFu));
}

void writeU32At(std::vector<uint8_t>& out, size_t off, uint32_t v) {
  out[off + 0] = static_cast<uint8_t>(v & 0xFFu);
  out[off + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  out[off + 2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
  out[off + 3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
}

void appendFixedStr(std::vector<uint8_t>& out, const char* s, size_t len) {
  const size_t slen = std::strlen(s);
  for (size_t i = 0; i < len; ++i) {
    out.push_back(i < slen ? static_cast<uint8_t>(s[i]) : 0u);
  }
}

std::vector<uint8_t> buildMinimalTestSf2() {
  std::vector<uint8_t> sf;
  appendFourCc(sf, "RIFF");
  const size_t riff_size_off = sf.size();
  appendU32(sf, 0);
  appendFourCc(sf, "sfbk");

  // 1. INFO LIST
  appendFourCc(sf, "LIST");
  const size_t info_size_off = sf.size();
  appendU32(sf, 0);
  appendFourCc(sf, "INFO");

  appendFourCc(sf, "ifil");
  appendU32(sf, 4);
  appendU16(sf, 2);
  appendU16(sf, 1);

  appendFourCc(sf, "isng");
  appendU32(sf, 8);
  appendFixedStr(sf, "EMU8000", 8);

  appendFourCc(sf, "INAM");
  appendU32(sf, 8);
  appendFixedStr(sf, "MuseApi", 8);

  writeU32At(sf, info_size_off,
             static_cast<uint32_t>(sf.size() - info_size_off - 4));

  // 2. sdta LIST
  constexpr uint32_t kLoopStart = 0;
  constexpr uint32_t kLoopEnd = 100;
  constexpr uint32_t kTotalSamples = 180;
  constexpr double kTwoPi = 6.28318530717958647692;

  appendFourCc(sf, "LIST");
  const size_t sdta_size_off = sf.size();
  appendU32(sf, 0);
  appendFourCc(sf, "sdta");

  appendFourCc(sf, "smpl");
  appendU32(sf, kTotalSamples * 2);
  for (uint32_t i = 0; i < kTotalSamples; ++i) {
    int16_t s = 0;
    if (i < kLoopEnd) {
      const double phase =
          kTwoPi * static_cast<double>(i) / static_cast<double>(kLoopEnd);
      s = static_cast<int16_t>(std::sin(phase) * 16000.0);
    }
    appendU16(sf, static_cast<uint16_t>(s));
  }

  writeU32At(sf, sdta_size_off,
             static_cast<uint32_t>(sf.size() - sdta_size_off - 4));

  // 3. pdta LIST
  appendFourCc(sf, "LIST");
  const size_t pdta_size_off = sf.size();
  appendU32(sf, 0);
  appendFourCc(sf, "pdta");

  // phdr (2 * 38 bytes)
  appendFourCc(sf, "phdr");
  appendU32(sf, 76);
  appendFixedStr(sf, "MuseApiSine", 20);
  appendU16(sf, 0); // preset 0
  appendU16(sf, 0); // bank 0
  appendU16(sf, 0);
  appendU32(sf, 0);
  appendU32(sf, 0);
  appendU32(sf, 0);
  appendFixedStr(sf, "EOP", 20);
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 1);
  appendU32(sf, 0);
  appendU32(sf, 0);
  appendU32(sf, 0);

  // pbag
  appendFourCc(sf, "pbag");
  appendU32(sf, 8);
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 1);
  appendU16(sf, 0);

  // pmod
  appendFourCc(sf, "pmod");
  appendU32(sf, 10);
  for (int i = 0; i < 5; ++i) {
    appendU16(sf, 0);
  }

  // pgen
  appendFourCc(sf, "pgen");
  appendU32(sf, 8);
  appendU16(sf, 41); // instrument
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 0);

  // inst
  appendFourCc(sf, "inst");
  appendU32(sf, 44);
  appendFixedStr(sf, "SineInst", 20);
  appendU16(sf, 0);
  appendFixedStr(sf, "EOI", 20);
  appendU16(sf, 1);

  // ibag
  appendFourCc(sf, "ibag");
  appendU32(sf, 8);
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 2);
  appendU16(sf, 0);

  // imod
  appendFourCc(sf, "imod");
  appendU32(sf, 10);
  for (int i = 0; i < 5; ++i) {
    appendU16(sf, 0);
  }

  // igen
  appendFourCc(sf, "igen");
  appendU32(sf, 12);
  appendU16(sf, 54); // sampleModes
  appendU16(sf, 1);  // continuous loop
  appendU16(sf, 53); // sampleID
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 0);

  // shdr
  appendFourCc(sf, "shdr");
  appendU32(sf, 92);
  appendFixedStr(sf, "SineWave", 20);
  appendU32(sf, kLoopStart);
  appendU32(sf, kLoopEnd + 16);
  appendU32(sf, kLoopStart);
  appendU32(sf, kLoopEnd);
  appendU32(sf, 48000);
  sf.push_back(60);
  sf.push_back(0);
  appendU16(sf, 0);
  appendU16(sf, 1);

  appendFixedStr(sf, "EOS", 20);
  for (int i = 0; i < 6; ++i) {
    appendU32(sf, 0);
  }
  appendU16(sf, 0);

  writeU32At(sf, pdta_size_off,
             static_cast<uint32_t>(sf.size() - pdta_size_off - 4));
  writeU32At(sf, riff_size_off,
             static_cast<uint32_t>(sf.size() - riff_size_off - 4));
  return sf;
}

float peakOfChannel(
    const std::vector<float>& interleaved,
    uint32_t channel,
    uint32_t total_channels) {
  float peak = 0.0f;
  const size_t frames = interleaved.size() / total_channels;
  for (size_t i = 0; i < frames; ++i) {
    peak = std::max(peak, std::fabs(interleaved[i * total_channels + channel]));
  }
  return peak;
}

std::string sha256File(const std::filesystem::path& path) {
  std::ifstream ifs(path, std::ios::binary);
  REQUIRE(ifs.is_open());
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(ifs)),
                             std::istreambuf_iterator<char>());
  return picosha2::hash256_hex_string(bytes);
}

} // namespace

TEST_CASE("C API mock HAL initialization, teardown, and fail-closed errors",
          "[c_api]") {
  HalRegistryResetGuard reset_hal;
  muse_engine_register_platform_hal(nullptr, nullptr);

  // 1. Null-handle and unregistered HAL fail closed.
  MuseEngineHandle engine = nullptr;
  MuseHardwareConfig out_cfg{};
  CHECK(muse_engine_create(nullptr, &out_cfg) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse_engine_create(&engine, nullptr) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse_engine_create(&engine, &out_cfg) == MUSE_ERR_DEVICE_INIT);
  CHECK(engine == nullptr);

  const MuseHardwareConfig valid_cfg = stereoTestConfig(48000, 2);
  CHECK(muse_engine_create_with_config(nullptr, &valid_cfg) ==
        MUSE_ERR_DEVICE_INIT);
  MuseEngineHandle existing_engine = nullptr;
  REQUIRE(muse_engine_create_with_config(&existing_engine, &valid_cfg) ==
          MUSE_OK);
  REQUIRE(existing_engine != nullptr);
  MuseEngineHandle probe_engine = existing_engine;
  CHECK(muse_engine_create_with_config(&probe_engine, nullptr) ==
        MUSE_ERR_DEVICE_INIT);
  CHECK(probe_engine == nullptr);
  muse_engine_destroy(existing_engine);
  muse_engine_destroy(nullptr);

  int32_t sf_id = 99;
  uint32_t preset_count = 99;
  CHECK(muse_engine_load_sf2_file(nullptr, "/tmp/unused.sf2", &sf_id, nullptr,
                                  0, &preset_count) == MUSE_ERR_DEVICE_INIT);
  CHECK(sf_id == kFluidSynthSfFailed);
  CHECK(preset_count == 0);

  sf_id = 99;
  preset_count = 99;
  CHECK(muse_engine_load_sf2_bytes(nullptr, nullptr, 0, &sf_id, nullptr, 0,
                                   &preset_count) == MUSE_ERR_DEVICE_INIT);
  CHECK(sf_id == kFluidSynthSfFailed);
  CHECK(preset_count == 0);
  CHECK(muse_engine_unload_sf2(nullptr, 1) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse_engine_push_mutation(nullptr, nullptr) == MUSE_ERR_DEVICE_INIT);
  CHECK(muse_engine_drain_telemetry(nullptr, nullptr, 4) == 0u);
  int64_t dummy_clock = 99;
  CHECK(muse_engine_drain_capture_frames(nullptr, nullptr, 4, &dummy_clock) ==
        0u);
  CHECK(dummy_clock == 0);

  // 2. Mock HAL init failure & start failure clean rollback.
  MockHalState state{};
  state.config = stereoTestConfig(48000, 1);
  g_mock_hal_state = &state;

  const IPlatformAudioHal mock_hal{
      mockHalInit,
      mockHalStart,
      mockHalStop,
      mockHalDispose,
  };
  muse_engine_register_platform_hal(&mock_hal, &state);

  state.fail_init = true;
  CHECK(muse_engine_create(&engine, &out_cfg) == MUSE_ERR_DEVICE_INIT);
  CHECK(engine == nullptr);
  CHECK(state.init_calls == 1);
  CHECK(state.start_calls == 0);

  state.fail_init = false;
  state.fail_start = true;
  CHECK(muse_engine_create(&engine, &out_cfg) == MUSE_ERR_DEVICE_INIT);
  CHECK(engine == nullptr);
  CHECK(state.init_calls == 2);
  CHECK(state.start_calls == 1);
  CHECK(state.dispose_calls == 1);

  // 3. Successful mock HAL initialization, callback pump, telemetry, destroy.
  state.fail_start = false;
  REQUIRE(muse_engine_create(&engine, &out_cfg) == MUSE_OK);
  REQUIRE(engine != nullptr);
  CHECK(out_cfg.sample_rate == 48000u);
  CHECK(out_cfg.input_channels == 1u);
  CHECK(out_cfg.output_channels == 2u);
  CHECK(std::strcmp(out_cfg.device_fingerprint, "c-api-integration-device") ==
        0);
  REQUIRE(state.last_callback != nullptr);
  REQUIRE(state.last_user_data != nullptr);

  std::array<float, 128> mock_in{};
  std::array<float, 128 * 2> mock_out{};
  mock_in.fill(0.0f);
  state.last_callback(state.last_user_data, mock_in.data(), mock_out.data(),
                      128);

  TelemetryFrame tf{};
  CHECK(muse_engine_drain_telemetry(engine, &tf, 1) == 1u);
  CHECK(tf.playhead_sample_frame == 0);

  muse_engine_destroy(engine);
  engine = nullptr;
  CHECK(state.stop_calls == 1);
  CHECK(state.dispose_calls == 2);
  g_mock_hal_state = nullptr;
}

TEST_CASE("C API loads in-memory SF2 presets, handles max_presets=0, rejects large files and playing load",
          "[c_api]") {
  const MuseHardwareConfig cfg = stereoTestConfig(48000, 2);
  EngineGuard guard;
  REQUIRE(muse_engine_create_with_config(&guard.handle, &cfg) == MUSE_OK);

  const std::vector<uint8_t> sf2 = buildMinimalTestSf2();

  // 1. max_presets == 0 triggers MUSE_ERR_BUFFER_TOO_SMALL + rollback & count.
  int32_t sf_id = -1;
  uint32_t count = 0;
  CHECK(muse_engine_load_sf2_bytes(guard.handle, sf2.data(),
                                   static_cast<uint32_t>(sf2.size()), &sf_id,
                                   nullptr, 0, &count) ==
        MUSE_ERR_BUFFER_TOO_SMALL);
  CHECK(sf_id == kFluidSynthSfFailed);
  CHECK(count == 1u);

  // 2. Null bytes or oversized (> kMaxWebSoundFontBytes) reject with SF_TOO_LARGE.
  sf_id = 42;
  CHECK(muse_engine_load_sf2_bytes(guard.handle, nullptr, 16, &sf_id, nullptr,
                                   0, &count) == MUSE_ERR_SF_TOO_LARGE);
  CHECK(sf_id == kFluidSynthSfFailed);

  std::array<uint8_t, 16> dummy{};
  CHECK(muse_engine_load_sf2_bytes(guard.handle, dummy.data(),
                                   kMaxWebSoundFontBytes + 1u, &sf_id, nullptr,
                                   0, &count) == MUSE_ERR_SF_TOO_LARGE);

  // 3. Valid load extracts preset metadata POD cleanly.
  MuseSoundFontPresetPod presets[4]{};
  REQUIRE(muse_engine_load_sf2_bytes(guard.handle, sf2.data(),
                                     static_cast<uint32_t>(sf2.size()), &sf_id,
                                     presets, 4, &count) == MUSE_OK);
  REQUIRE(sf_id > 0);
  REQUIRE(count == 1u);
  CHECK(presets[0].bank_num == 0);
  CHECK(presets[0].program_num == 0);
  CHECK(std::strcmp(presets[0].preset_name, "MuseApiSine") == 0);

  // 4. Also verify POSIX file SF2 loading + unload round-trip.
  const auto sf2_path =
      std::filesystem::temp_directory_path() / "muse_c_api_test.sf2";
  TempFileGuard file_guard{sf2_path};
  {
    std::ofstream ofs(sf2_path, std::ios::binary);
    REQUIRE(ofs.is_open());
    ofs.write(reinterpret_cast<const char*>(sf2.data()),
              static_cast<std::streamsize>(sf2.size()));
    REQUIRE(ofs.good());
  }
  int32_t file_sf_id = -1;
  MuseSoundFontPresetPod file_presets[2]{};
  uint32_t file_count = 0;
  REQUIRE(muse_engine_load_sf2_file(guard.handle, sf2_path.string().c_str(),
                                    &file_sf_id, file_presets, 2,
                                    &file_count) == MUSE_OK);
  CHECK(file_sf_id > 0);
  CHECK(file_count == 1u);
  CHECK(muse_engine_unload_sf2(guard.handle, file_sf_id) == MUSE_OK);

  // 5. Reject in-memory SF2 load when MUT_SET_PLAYING(1) is queued even before processBlock().
  MutationCommand play_cmd{};
  play_cmd.type = MUT_SET_PLAYING;
  play_cmd.flag_a = 1;
  REQUIRE(muse_engine_push_mutation(guard.handle, &play_cmd) == MUSE_OK);

  int32_t playing_sf = -1;
  uint32_t playing_cnt = 0;
  CHECK(muse_engine_load_sf2_bytes(guard.handle, sf2.data(),
                                   static_cast<uint32_t>(sf2.size()),
                                   &playing_sf, presets, 4, &playing_cnt) ==
        MUSE_ERR_TRANSPORT_NOT_STOPPED);
  CHECK(playing_sf == kFluidSynthSfFailed);

  std::vector<float> tmp_out(64 * 2, 0.0f);
  REQUIRE(muse_engine_process_block(guard.handle, nullptr, tmp_out.data(), 64) ==
          MUSE_OK);
  CHECK(muse_engine_load_sf2_bytes(guard.handle, sf2.data(),
                                   static_cast<uint32_t>(sf2.size()),
                                   &playing_sf, presets, 4, &playing_cnt) ==
        MUSE_ERR_TRANSPORT_NOT_STOPPED);
  CHECK(playing_sf == kFluidSynthSfFailed);
}

TEST_CASE("C API lookahead MIDI, +6 dB pan isolation, and epoch flush silence",
          "[c_api]") {
  const MuseHardwareConfig cfg = stereoTestConfig(48000, 2);
  EngineGuard guard;
  REQUIRE(muse_engine_create_with_config(&guard.handle, &cfg) == MUSE_OK);

  const std::vector<uint8_t> sf2 = buildMinimalTestSf2();
  int32_t sf_id = -1;
  MuseSoundFontPresetPod preset{};
  uint32_t count = 0;
  REQUIRE(muse_engine_load_sf2_bytes(guard.handle, sf2.data(),
                                     static_cast<uint32_t>(sf2.size()), &sf_id,
                                     &preset, 1, &count) == MUSE_OK);

  // Route channel 0 & 1 to bank 0 prog 0; test +6 dB hard-left on ch 0.
  MutationCommand patch{};
  patch.type = MUT_ASSIGN_CHANNEL_PATCH;
  patch.channel = 0;
  patch.int_param_a = sf_id;
  patch.int_param_b = 0;
  patch.int_param_c = 0;
  REQUIRE(muse_engine_push_mutation(guard.handle, &patch) == MUSE_OK);

  MutationCommand mix_unity{};
  mix_unity.type = MUT_SET_CHANNEL_MIX;
  mix_unity.channel = 0;
  mix_unity.float_param_a = 0.0f;
  mix_unity.float_param_b = kMinPan; // hard left

  MutationCommand play_cmd{};
  play_cmd.type = MUT_SET_PLAYING;
  play_cmd.flag_a = 1;

  REQUIRE(muse_engine_push_mutation(guard.handle, &mix_unity) == MUSE_OK);
  REQUIRE(muse_engine_push_mutation(guard.handle, &play_cmd) == MUSE_OK);

  // Baseline unity hard-left note on [0, 512)
  SynthNoteEvent note_unity{};
  note_unity.epoch = 0;
  note_unity.target_sample_frame = 0;
  note_unity.type = EVT_NOTE_ON;
  note_unity.channel = 0;
  note_unity.key_or_cc = 60;
  note_unity.velocity_or_val = 100;
  uint32_t pushed = 0;
  REQUIRE(muse_engine_push_events(guard.handle, &note_unity, 1, &pushed) ==
          MUSE_OK);
  REQUIRE(pushed == 1u);

  std::vector<float> unity_out(512 * 2, 0.0f);
  REQUIRE(muse_engine_process_block(guard.handle, nullptr, unity_out.data(),
                                    512) == MUSE_OK);
  const float unity_left_peak = peakOfChannel(unity_out, 0, 2);
  REQUIRE(unity_left_peak > 0.01f);
  CHECK(peakOfChannel(unity_out, 1, 2) < 1e-5f);

  // Flush & advance to epoch 1 and drain baseline note release tail to silence.
  MutationCommand flush_cmd{};
  flush_cmd.type = MUT_FLUSH_AND_ADVANCE_EPOCH;
  flush_cmd.target_epoch = 1;
  REQUIRE(muse_engine_push_mutation(guard.handle, &flush_cmd) == MUSE_OK);

  std::vector<float> release_drain(4096 * 2, 0.0f);
  for (int b = 0; b < 4; ++b) {
    REQUIRE(muse_engine_process_block(guard.handle, nullptr,
                                      release_drain.data(), 4096) == MUSE_OK);
  }

  // Seek back to 0 at epoch 1 and switch ch 0 to +6 dB hard right.
  MutationCommand seek0{};
  seek0.type = MUT_SEEK_SAMPLE;
  seek0.sample_frame_a = 0;
  seek0.target_epoch = 1;
  REQUIRE(muse_engine_push_mutation(guard.handle, &seek0) == MUSE_OK);

  MutationCommand mix_boost{};
  mix_boost.type = MUT_SET_CHANNEL_MIX;
  mix_boost.channel = 0;
  mix_boost.float_param_a = 6.0f;
  mix_boost.float_param_b = kMaxPan; // hard right
  REQUIRE(muse_engine_push_mutation(guard.handle, &mix_boost) == MUSE_OK);

  // Stale epoch 0 event must be dropped, while epoch 1 note on [100, 400) plays.
  SynthNoteEvent events[3]{};
  events[0].epoch = 0;
  events[0].target_sample_frame = 0;
  events[0].type = EVT_NOTE_ON;
  events[0].channel = 0;
  events[0].key_or_cc = 64;
  events[0].velocity_or_val = 127;

  events[1].epoch = 1;
  events[1].target_sample_frame = 100;
  events[1].type = EVT_NOTE_ON;
  events[1].channel = 0;
  events[1].key_or_cc = 60;
  events[1].velocity_or_val = 100;

  events[2].epoch = 1;
  events[2].target_sample_frame = 400;
  events[2].type = EVT_NOTE_OFF;
  events[2].channel = 0;
  events[2].key_or_cc = 60;
  events[2].velocity_or_val = 0;

  REQUIRE(muse_engine_push_events(guard.handle, events, 3, &pushed) == MUSE_OK);
  REQUIRE(pushed == 3u);

  std::vector<float> boost_out(512 * 2, 0.0f);
  REQUIRE(muse_engine_process_block(guard.handle, nullptr, boost_out.data(),
                                    512) == MUSE_OK);

  // Frames [0, 100) before note-on had stale epoch 0 dropped -> silent.
  float pre_note_peak = 0.0f;
  for (size_t i = 0; i < 100 * 2; ++i) {
    pre_note_peak = std::max(pre_note_peak, std::fabs(boost_out[i]));
  }
  CHECK(pre_note_peak < 1e-4f);

  // Hard right isolation & +6 dB boost (~2x unity_left_peak unless limited).
  CHECK(peakOfChannel(boost_out, 0, 2) < 1e-5f);
  const float boosted_right_peak = peakOfChannel(boost_out, 1, 2);
  CHECK(boosted_right_peak > unity_left_peak * 1.5f);

  // Flush epoch to 2 and let FluidSynth release decay -> silence on new epoch.
  MutationCommand flush2{};
  flush2.type = MUT_FLUSH_AND_ADVANCE_EPOCH;
  flush2.target_epoch = 2;
  REQUIRE(muse_engine_push_mutation(guard.handle, &flush2) == MUSE_OK);

  std::vector<float> tail(4096 * 2, 0.0f);
  for (int b = 0; b < 8; ++b) {
    REQUIRE(muse_engine_process_block(guard.handle, nullptr, tail.data(),
                                      4096) == MUSE_OK);
  }
  CHECK(peakOfChannel(tail, 0, 2) < 1e-4f);
  CHECK(peakOfChannel(tail, 1, 2) < 1e-4f);
}

TEST_CASE("C API records WAV with receipt/SHA-256 and supports non-Butler drain_capture_frames",
          "[c_api]") {
  const auto wav_path =
      std::filesystem::temp_directory_path() / "muse_c_api_capture.wav.part";
  TempFileGuard wav_guard{wav_path};
  std::filesystem::remove(wav_path);

  const MuseHardwareConfig cfg = stereoTestConfig(48000, 2);
  EngineGuard guard;
  REQUIRE(muse_engine_create_with_config(&guard.handle, &cfg) == MUSE_OK);

  // Warm up 128 frames so hardware sample_clock latches at 128.
  std::vector<float> warmup_out(128 * 2, 0.0f);
  REQUIRE(muse_engine_process_block(guard.handle, nullptr, warmup_out.data(),
                                    128) == MUSE_OK);

  MutationCommand seek{};
  seek.type = MUT_SEEK_SAMPLE;
  seek.sample_frame_a = 900;
  REQUIRE(muse_engine_push_mutation(guard.handle, &seek) == MUSE_OK);

  REQUIRE(muse_engine_prepare_capture(guard.handle, wav_path.string().c_str()) ==
          MUSE_OK);
  REQUIRE(muse_engine_start_capture(guard.handle) == MUSE_OK);

  // While Butler owns capture, C API direct drain returns 0.
  std::vector<float> blocked_drain(64 * 2, 0.0f);
  int64_t blocked_clk = -1;
  CHECK(muse_engine_drain_capture_frames(guard.handle, blocked_drain.data(), 64,
                                         &blocked_clk) == 0u);

  constexpr uint32_t kCaptureFrames = 3072;
  std::vector<float> mic_in(kCaptureFrames * 2, 0.0f);
  for (uint32_t i = 0; i < kCaptureFrames; ++i) {
    mic_in[i * 2 + 0] = -0.35f + 0.0001f * static_cast<float>(i & 255u);
    mic_in[i * 2 + 1] = 0.45f - 0.0001f * static_cast<float>(i & 255u);
  }
  std::vector<float> monitor_out(kCaptureFrames * 2, 0.0f);
  REQUIRE(muse_engine_process_block(guard.handle, mic_in.data(),
                                    monitor_out.data(),
                                    kCaptureFrames) == MUSE_OK);

  FinalizedCaptureReceipt receipt{};
  REQUIRE(muse_engine_stop_and_finalize_capture(guard.handle, &receipt) ==
          MUSE_OK);
  CHECK(sizeof(FinalizedCaptureReceipt) == 632);
  CHECK(receipt.status == MUSE_OK);
  CHECK(receipt.captured_sample_clock == 128);
  CHECK(receipt.captured_playhead_frame == 900);
  CHECK(receipt.duration_frames == static_cast<int64_t>(kCaptureFrames));
  CHECK(receipt.sample_rate == 48000u);
  CHECK(receipt.channel_count == 2u);
  CHECK(receipt.output_buffer_frames == 256u);
  CHECK(receipt.input_buffer_frames == 256u);
  CHECK(std::strcmp(receipt.staging_path, wav_path.string().c_str()) == 0);
  CHECK(std::strcmp(receipt.sha256_hex, sha256File(wav_path).c_str()) == 0);

  // Non-Butler direct C API capture drain path (e.g., Web AudioWorklet consumer).
  EngineGuard direct_guard;
  REQUIRE(muse_engine_create_with_config(&direct_guard.handle, &cfg) ==
          MUSE_OK);

  constexpr uint32_t kDirectWarmup = 64;
  std::vector<float> direct_warmup(kDirectWarmup * 2, 0.0f);
  REQUIRE(muse_engine_process_block(direct_guard.handle, nullptr,
                                    direct_warmup.data(), kDirectWarmup) ==
          MUSE_OK);

  MutationCommand arm_direct{};
  arm_direct.type = MUT_SET_CAPTURE_STATE;
  arm_direct.flag_a = 1;
  REQUIRE(muse_engine_push_mutation(direct_guard.handle, &arm_direct) ==
          MUSE_OK);

  constexpr uint32_t kDirectFrames = 300;
  std::vector<float> direct_in(kDirectFrames * 2, 0.0f);
  for (size_t i = 0; i < direct_in.size(); ++i) {
    direct_in[i] = 0.001f * static_cast<float>(i);
  }
  std::vector<float> direct_out(kDirectFrames * 2, 0.0f);
  REQUIRE(muse_engine_process_block(direct_guard.handle, direct_in.data(),
                                    direct_out.data(),
                                    kDirectFrames) == MUSE_OK);

  // Stop capture so only those 300 frames remain.
  arm_direct.flag_a = 0;
  REQUIRE(muse_engine_push_mutation(direct_guard.handle, &arm_direct) ==
          MUSE_OK);
  std::vector<float> settle_out(16 * 2, 0.0f);
  REQUIRE(muse_engine_process_block(direct_guard.handle, nullptr,
                                    settle_out.data(), 16) == MUSE_OK);

  const int64_t expected_start_clk = static_cast<int64_t>(kDirectWarmup);
  std::vector<float> part1(150 * 2, 0.0f);
  int64_t clk1 = -1;
  CHECK(muse_engine_drain_capture_frames(direct_guard.handle, part1.data(), 150,
                                         &clk1) == 150u);
  CHECK(clk1 == expected_start_clk);

  std::vector<float> part2(200 * 2, 0.0f);
  int64_t clk2 = -1;
  CHECK(muse_engine_drain_capture_frames(direct_guard.handle, part2.data(), 200,
                                         &clk2) == 150u);
  CHECK(clk2 == expected_start_clk + 150);

  int64_t clk3 = -1;
  CHECK(muse_engine_drain_capture_frames(direct_guard.handle, part2.data(), 200,
                                         &clk3) == 0u);

  for (uint32_t i = 0; i < 150 * 2; ++i) {
    CHECK_THAT(part1[i], Catch::Matchers::WithinAbs(direct_in[i], 1e-6f));
    CHECK_THAT(part2[i],
               Catch::Matchers::WithinAbs(direct_in[150 * 2 + i], 1e-6f));
  }
}
