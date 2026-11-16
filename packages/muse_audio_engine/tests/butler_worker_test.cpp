#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_floating_point.hpp>

#include <algorithm>
#include <array>
#include <chrono>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <filesystem>
#include <fstream>
#include <memory>
#include <thread>
#include <vector>

#include <miniaudio.h>
#include <picosha2.h>

#include "audio_engine_core.h"

namespace {

using namespace muse::engine;

struct TempFileGuard {
  std::filesystem::path path;
  ~TempFileGuard() {
    std::error_code ec;
    std::filesystem::remove(path, ec);
  }
};

MuseHardwareConfig stereoConfig(uint32_t sample_rate, uint32_t input_ch) {
  MuseHardwareConfig cfg{};
  cfg.sample_rate = sample_rate;
  cfg.input_channels = input_ch;
  cfg.output_channels = 2;
  cfg.input_buffer_frames = 512;
  cfg.output_buffer_frames = 512;
  std::snprintf(cfg.device_fingerprint, sizeof(cfg.device_fingerprint),
                "butler-test");
  return cfg;
}

void writeMonoF32Wav(
    const std::filesystem::path& path,
    uint32_t sample_rate,
    const std::vector<float>& samples) {
  ma_encoder_config cfg =
      ma_encoder_config_init(ma_encoding_format_wav, ma_format_f32, 1, sample_rate);
  ma_encoder encoder{};
  REQUIRE(ma_encoder_init_file(path.string().c_str(), &cfg, &encoder) ==
          MA_SUCCESS);
  ma_uint64 written = 0;
  REQUIRE(ma_encoder_write_pcm_frames(&encoder, samples.data(), samples.size(),
                                      &written) == MA_SUCCESS);
  REQUIRE(written == samples.size());
  ma_encoder_uninit(&encoder);
}

std::string sha256OfFile(const std::filesystem::path& path) {
  std::ifstream ifs(path, std::ios::binary);
  REQUIRE(ifs.is_open());
  std::vector<uint8_t> bytes((std::istreambuf_iterator<char>(ifs)),
                             std::istreambuf_iterator<char>());
  return picosha2::hash256_hex_string(bytes);
}

struct MockHalState {
  MuseHardwareConfig config{};
  void* last_user_data = nullptr;
  MuseAudioProcessCallback last_callback = nullptr;
};

MockHalState* g_butler_mock_hal = nullptr;

MuseStatus mockHalInit(
    void* user_data,
    MuseAudioProcessCallback callback,
    MuseHardwareConfig* out_config) {
  if (g_butler_mock_hal == nullptr || out_config == nullptr) {
    return MUSE_ERR_DEVICE_INIT;
  }
  g_butler_mock_hal->last_user_data = user_data;
  g_butler_mock_hal->last_callback = callback;
  *out_config = g_butler_mock_hal->config;
  return MUSE_OK;
}

MuseStatus mockHalStart(void* /*hal_handle*/) { return MUSE_OK; }
MuseStatus mockHalStop(void* /*hal_handle*/) { return MUSE_OK; }
void mockHalDispose(void* /*hal_handle*/) {}

} // namespace

TEST_CASE("ButlerWorker records WAV with valid RIFF header, clocks, and SHA-256",
          "[butler_worker]") {
  const auto temp_wav = std::filesystem::temp_directory_path() /
      "muse_butler_capture_test.wav.part";
  TempFileGuard cleanup{temp_wav};
  std::filesystem::remove(temp_wav);

  auto core_storage = std::make_unique<AudioEngineCore>();
  auto& core = *core_storage;
  REQUIRE(core.initializeWithConfig(stereoConfig(48000, 2)) == MUSE_OK);

  // Advance hardware clock by 256 frames before capture arms.
  std::vector<float> warmup_out(256 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, warmup_out.data(), 256) == MUSE_OK);

  MutationCommand seek{};
  seek.type = MUT_SEEK_SAMPLE;
  seek.sample_frame_a = 1500;
  REQUIRE(core.pushMutation(seek) == MUSE_OK);

  REQUIRE(core.prepareCapture(temp_wav.string().c_str()) == MUSE_OK);

  // Butler owns capture on Native, so C/Web batch drain must fail closed.
  std::array<float, 16> blocked_drain{};
  int64_t dummy_clk = 0;
  CHECK(core.drainCaptureFrames(blocked_drain.data(), 8, &dummy_clk) == 0);

  REQUIRE(core.startCapture() == MUSE_OK);

  constexpr uint32_t kBlockFrames = 512;
  constexpr uint32_t kNumBlocks = 12;
  constexpr double kTwoPi = 6.28318530717958647692;
  std::vector<float> mic(kBlockFrames * 2, 0.0f);
  std::vector<float> out(kBlockFrames * 2, 0.0f);
  std::vector<float> expected_all;
  expected_all.reserve(kNumBlocks * kBlockFrames * 2);

  for (uint32_t b = 0; b < kNumBlocks; ++b) {
    for (uint32_t f = 0; f < kBlockFrames; ++f) {
      const uint32_t idx = b * kBlockFrames + f;
      const float val =
          0.4f * static_cast<float>(std::sin(kTwoPi * 440.0 * idx / 48000.0));
      mic[f * 2 + 0] = val;
      mic[f * 2 + 1] = -val;
      expected_all.push_back(val);
      expected_all.push_back(-val);
    }
    REQUIRE(core.processBlock(mic.data(), out.data(), kBlockFrames) == MUSE_OK);
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }

  FinalizedCaptureReceipt receipt{};
  REQUIRE(core.stopAndFinalizeCapture(&receipt) == MUSE_OK);
  CHECK(receipt.status == MUSE_OK);
  CHECK(receipt.captured_sample_clock == 256);
  CHECK(receipt.captured_playhead_frame == 1500);
  CHECK(receipt.duration_frames ==
        static_cast<int64_t>(kBlockFrames * kNumBlocks));
  CHECK(receipt.sample_rate == 48000);
  CHECK(receipt.channel_count == 2);
  CHECK(receipt.output_buffer_frames == 512);
  CHECK(receipt.input_buffer_frames == 512);
  CHECK(std::string(receipt.staging_path) == temp_wav.string());
  CHECK(std::string(receipt.sha256_hex) == sha256OfFile(temp_wav));

  // Verify finalized RIFF WAV integrity via miniaudio decoder.
  ma_decoder_config dec_cfg = ma_decoder_config_init(ma_format_f32, 2, 48000);
  ma_decoder dec{};
  REQUIRE(ma_decoder_init_file(temp_wav.string().c_str(), &dec_cfg, &dec) ==
          MA_SUCCESS);
  ma_uint64 decoded_frames = 0;
  REQUIRE(ma_decoder_get_length_in_pcm_frames(&dec, &decoded_frames) ==
          MA_SUCCESS);
  CHECK(decoded_frames == kBlockFrames * kNumBlocks);
  std::vector<float> decoded(decoded_frames * 2, 0.0f);
  ma_uint64 frames_read = 0;
  REQUIRE(ma_decoder_read_pcm_frames(&dec, decoded.data(), decoded_frames,
                                     &frames_read) == MA_SUCCESS);
  REQUIRE(frames_read == decoded_frames);
  ma_decoder_uninit(&dec);

  for (size_t i = 0; i < expected_all.size(); ++i) {
    CHECK_THAT(decoded[i], Catch::Matchers::WithinAbs(expected_all[i], 1e-5f));
  }
}

TEST_CASE("ButlerWorker fails closed on capture ring overflow and playback-only init",
          "[butler_worker]") {
  auto playback_only_storage = std::make_unique<AudioEngineCore>();
  auto& playback_only = *playback_only_storage;
  REQUIRE(playback_only.initializeWithConfig(stereoConfig(48000, 0)) == MUSE_OK);
  CHECK(playback_only.prepareCapture("/tmp/muse_pb_only.wav.part") ==
        MUSE_ERR_DEVICE_INIT);

  const auto overflow_wav = std::filesystem::temp_directory_path() /
      "muse_butler_overflow_test.wav.part";
  TempFileGuard cleanup{overflow_wav};
  std::filesystem::remove(overflow_wav);

  auto core_storage = std::make_unique<AudioEngineCore>();
  auto& core = *core_storage;
  REQUIRE(core.initializeWithConfig(stereoConfig(48000, 2)) == MUSE_OK);
  REQUIRE(core.prepareCapture(overflow_wav.string().c_str()) == MUSE_OK);
  REQUIRE(std::filesystem::exists(overflow_wav));
  core.setCaptureDrainPaused(true);
  REQUIRE(core.startCapture() == MUSE_OK);

  // Saturate CaptureRingBuffer (65536 frames * 2 channels) while Butler drain
  // experiences disk backpressure (paused), forcing an RT ring overflow on the
  // 17th 4096-frame block.
  std::vector<float> mic(kMaxRenderBlockFrames * 2, 0.125f);
  std::vector<float> out(kMaxRenderBlockFrames * 2, 0.0f);
  for (int i = 0; i < 18 && !core.didCaptureOverflow(); ++i) {
    REQUIRE(core.processBlock(mic.data(), out.data(), kMaxRenderBlockFrames) ==
            MUSE_OK);
  }
  REQUIRE(core.didCaptureOverflow());
  core.setCaptureDrainPaused(false);

  FinalizedCaptureReceipt receipt{};
  const MuseStatus fin_st = core.stopAndFinalizeCapture(&receipt);
  CHECK(fin_st == MUSE_ERR_CAPTURE_OVERFLOW);
  CHECK(receipt.status == MUSE_ERR_CAPTURE_OVERFLOW);
  CHECK(std::strlen(receipt.staging_path) == 0);
  CHECK(std::strlen(receipt.sha256_hex) == 0);
  CHECK(!std::filesystem::exists(overflow_wav));
}

TEST_CASE("ButlerWorker resamples 44.1kHz mono WAV takes, sums overlaps, and wraps loops",
          "[butler_worker]") {
  const auto wav_a =
      std::filesystem::temp_directory_path() / "muse_take_a_44k.wav";
  const auto wav_b =
      std::filesystem::temp_directory_path() / "muse_take_b_44k.wav";
  TempFileGuard guard_a{wav_a};
  TempFileGuard guard_b{wav_b};

  // Write 0.1s (4410 frames) at 44100 Hz mono constant amplitudes so resampled
  // steady-state output (~4800 frames at 48000 Hz) avoids phase offsets.
  writeMonoF32Wav(wav_a, 44100, std::vector<float>(4410, 0.8f));
  writeMonoF32Wav(wav_b, 44100, std::vector<float>(4410, 0.2f));

  auto core_storage = std::make_unique<AudioEngineCore>();
  auto& core = *core_storage;
  REQUIRE(core.initializeWithConfig(stereoConfig(48000, 2)) == MUSE_OK);

  // Take A starts at 0 with explicit clamp duration 400 (shorter than ~4800).
  REQUIRE(core.registerActiveTake("take_a", wav_a.string().c_str(), 0, 400,
                                  -6.0f, kMaxPan) == MUSE_OK);
  // Take B overlaps [128, 300) at unity gain, also hard-right.
  REQUIRE(core.registerActiveTake("take_b", wav_b.string().c_str(), 128, 172,
                                  0.0f, kMaxPan) == MUSE_OK);

  MutationCommand loop_cmd{};
  loop_cmd.type = MUT_SET_LOOP_REGION;
  loop_cmd.flag_a = 1;
  loop_cmd.sample_frame_a = 100;
  loop_cmd.sample_frame_b = 300;
  REQUIRE(core.pushMutation(loop_cmd) == MUSE_OK);

  // Seek while paused so ButlerWorker prefills TakePlaybackRingBuffer from
  // timeline frame 0 with the active loop window armed.
  MutationCommand seek0{};
  seek0.type = MUT_SEEK_SAMPLE;
  seek0.sample_frame_a = 0;
  seek0.target_epoch = 1;
  REQUIRE(core.pushMutation(seek0) == MUSE_OK);

  std::vector<float> prime_out(16 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, prime_out.data(), 16) == MUSE_OK);

  const auto wait_deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  bool prefetch_ready = false;
  std::array<float, 16 * 2> settle_out{};
  while (std::chrono::steady_clock::now() < wait_deadline) {
    REQUIRE(core.processBlock(nullptr, settle_out.data(), 16) == MUSE_OK);

    const TakePlaybackStereoFrame* first =
        core.takePlaybackRingBuffer().peek();
    prefetch_ready =
        first != nullptr && first->epoch == core.activeEpochAtomic() &&
        first->target_sample_frame == 0 &&
        core.takePlaybackReadAvailable() >= 1024;
    if (prefetch_ready) {
      break;
    }
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  REQUIRE(prefetch_ready);

  MutationCommand play_cmd{};
  play_cmd.type = MUT_SET_PLAYING;
  play_cmd.flag_a = 1;
  REQUIRE(core.pushMutation(play_cmd) == MUSE_OK);

  const float expected_a = 0.8f * dsp::dbToLinear(-6.0f);
  const float expected_sum = expected_a + 0.2f;

  // Render [0..100) before loop + [100..200) inside loop + [200..300) -> wrap to 100 -> [100..160)
  std::vector<float> block1(128 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, block1.data(), 128) == MUSE_OK);
  // Check middle sample [50] cleanly past initial sinc filter warm-up (resampler kernel edge)
  CHECK(std::fabs(block1[50 * 2 + 0]) < 1e-5f);
  CHECK_THAT(block1[50 * 2 + 1], Catch::Matchers::WithinAbs(expected_a, 0.02f));

  // Ensure Butler keeps prefetching across overlap [128, 300) and loop wrap 300 -> 100.
  std::this_thread::sleep_for(std::chrono::milliseconds(10));
  std::vector<float> block2(256 * 2, 0.0f);
  // Playhead goes 128 -> 300 (172 frames) then wraps to 100 -> 184 (84 frames).
  REQUIRE(core.processBlock(nullptr, block2.data(), 256) == MUSE_OK);
  CHECK(core.playheadAtomic() == 184);

  // Frame 40 of block2 is timeline 168 (overlap of A + B).
  CHECK(std::fabs(block2[40 * 2 + 0]) < 1e-5f);
  CHECK_THAT(block2[40 * 2 + 1],
             Catch::Matchers::WithinAbs(expected_sum, 0.03f));

  // Frame 210 of block2 is post-wrap timeline 100 + 38 = 138 (still overlap of A + B!).
  CHECK(std::fabs(block2[210 * 2 + 0]) < 1e-5f);
  CHECK_THAT(block2[210 * 2 + 1],
             Catch::Matchers::WithinAbs(expected_sum, 0.03f));

  TelemetryFrame tf{};
  while (core.drainTelemetry(&tf, 1) == 1) {
    CHECK(tf.take_playback_underrun == 0);
  }

  // Test duration clamp against massive requested duration_frames.
  REQUIRE(core.clearActiveTakes() == MUSE_OK);
  REQUIRE(core.registerActiveTake("take_clamped", wav_a.string().c_str(), 1000,
                                  9999999, 0.0f, kCenterPan) == MUSE_OK);
  // Seek to 1000 + 5200 (past ~4800 resampled length): window must NOT report
  // underrun because duration_frames was clamped to actual decoded length.
  MutationCommand disable_loop{};
  disable_loop.type = MUT_SET_LOOP_REGION;
  disable_loop.flag_a = 0;
  disable_loop.sample_frame_a = 0;
  REQUIRE(core.pushMutation(disable_loop) == MUSE_OK);

  MutationCommand seek_past{};
  seek_past.type = MUT_SEEK_SAMPLE;
  seek_past.target_epoch = 2;
  seek_past.sample_frame_a = 6200;
  REQUIRE(core.pushMutation(seek_past) == MUSE_OK);

  std::vector<float> silence_out(64 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, silence_out.data(), 64) == MUSE_OK);
  TelemetryFrame tf_past{};
  REQUIRE(core.drainTelemetry(&tf_past, 1) == 1);
  CHECK(tf_past.take_playback_underrun == 0);
}

TEST_CASE("ButlerWorker prefetches paused take without seek, replaces duplicate take_id, and silences on clear",
          "[butler_worker]") {
  const auto wav_v1 =
      std::filesystem::temp_directory_path() / "muse_take_dup_v1.wav";
  const auto wav_v2 =
      std::filesystem::temp_directory_path() / "muse_take_dup_v2.wav";
  TempFileGuard guard_v1{wav_v1};
  TempFileGuard guard_v2{wav_v2};

  writeMonoF32Wav(wav_v1, 48000, std::vector<float>(2048, 0.3f));
  writeMonoF32Wav(wav_v2, 48000, std::vector<float>(2048, -0.6f));

  auto core_storage = std::make_unique<AudioEngineCore>();
  auto& core = *core_storage;
  REQUIRE(core.initializeWithConfig(stereoConfig(48000, 2)) == MUSE_OK);

  // Fill remaining kMaxActiveTakeRegions - 1 slots far downstream so we also
  // verify duplicate take_id replaces in place without exhausting slots.
  for (uint32_t s = 1; s < kMaxActiveTakeRegions; ++s) {
    const std::string dummy_id = "dummy_slot_" + std::to_string(s);
    REQUIRE(core.registerActiveTake(dummy_id.c_str(), wav_v1.string().c_str(),
                                    100000 + static_cast<int64_t>(s) * 4096,
                                    2048, 0.0f, kCenterPan) == MUSE_OK);
  }

  // Register while paused WITHOUT pushing any MUT_SEEK_SAMPLE.
  REQUIRE(core.registerActiveTake("take_dup", wav_v1.string().c_str(), 0, 2048,
                                  0.0f, kCenterPan) == MUSE_OK);

  const auto deadline1 =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  while (core.takePlaybackReadAvailable() < 1024 &&
         std::chrono::steady_clock::now() < deadline1) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  REQUIRE(core.takePlaybackReadAvailable() >= 1024);

  // Replace "take_dup" in-place with wav_v2 while paused and still at frame 0.
  REQUIRE(core.registerActiveTake("take_dup", wav_v2.string().c_str(), 0, 2048,
                                  0.0f, kCenterPan) == MUSE_OK);

  const auto deadline2 =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  while (core.takePlaybackReadAvailable() < 1024 &&
         std::chrono::steady_clock::now() < deadline2) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  REQUIRE(core.takePlaybackReadAvailable() >= 1024);

  MutationCommand play_cmd{};
  play_cmd.type = MUT_SET_PLAYING;
  play_cmd.flag_a = 1;
  REQUIRE(core.pushMutation(play_cmd) == MUSE_OK);

  std::vector<float> out_v2(128 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, out_v2.data(), 128) == MUSE_OK);
  const float expected_center =
      -0.6f * dsp::computeConstantPowerPan(kCenterPan).left;
  CHECK_THAT(out_v2[16 * 2 + 0],
             Catch::Matchers::WithinAbs(expected_center, 1e-4f));
  CHECK_THAT(out_v2[16 * 2 + 1],
             Catch::Matchers::WithinAbs(expected_center, 1e-4f));

  // clearActiveTakes() must immediately discard prefetched frames & silence audio.
  REQUIRE(core.clearActiveTakes() == MUSE_OK);
  CHECK(core.takePlaybackReadAvailable() == 0);

  std::vector<float> out_cleared(128 * 2, 1.0f);
  REQUIRE(core.processBlock(nullptr, out_cleared.data(), 128) == MUSE_OK);
  for (float sample : out_cleared) {
    CHECK(sample == 0.0f);
  }
  TelemetryFrame tf{};
  while (core.drainTelemetry(&tf, 1) == 1) {
    CHECK(tf.take_playback_underrun == 0);
  }

  // Verify loop underrun recovery re-aligns prefetch cursor cleanly.
  REQUIRE(core.registerActiveTake("take_loop_recover", wav_v1.string().c_str(),
                                  0, 2048, 0.0f, kCenterPan) == MUSE_OK);
  MutationCommand pause_cmd{};
  pause_cmd.type = MUT_SET_PLAYING;
  pause_cmd.flag_a = 0;
  REQUIRE(core.pushMutation(pause_cmd) == MUSE_OK);

  MutationCommand seek0{};
  seek0.type = MUT_SEEK_SAMPLE;
  seek0.sample_frame_a = 0;
  seek0.target_epoch = 10;
  REQUIRE(core.pushMutation(seek0) == MUSE_OK);

  MutationCommand loop_cmd{};
  loop_cmd.type = MUT_SET_LOOP_REGION;
  loop_cmd.flag_a = 1;
  loop_cmd.sample_frame_a = 0;
  loop_cmd.sample_frame_b = 200;
  REQUIRE(core.pushMutation(loop_cmd) == MUSE_OK);

  std::vector<float> settle(16 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, settle.data(), 16) == MUSE_OK);

  const auto deadline3 =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  while (core.takePlaybackReadAvailable() < static_cast<size_t>(kTakePrefetchFrames) &&
         std::chrono::steady_clock::now() < deadline3) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  REQUIRE(core.takePlaybackReadAvailable() >= static_cast<size_t>(kTakePrefetchFrames));

  // Consume past kTakePrefetchFrames in one burst to force loop underrun.
  REQUIRE(core.pushMutation(play_cmd) == MUSE_OK);
  constexpr uint32_t kBurstFrames = 20000;
  std::vector<float> burst_out(kBurstFrames * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, burst_out.data(), kBurstFrames) == MUSE_OK);

  const auto deadline4 =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  while (core.takePlaybackReadAvailable() < 1024 &&
         std::chrono::steady_clock::now() < deadline4) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  REQUIRE(core.takePlaybackReadAvailable() >= 1024);

  // Drain any telemetry produced during the intentional underrun burst.
  while (core.drainTelemetry(&tf, 1) == 1) {
  }

  std::vector<float> recovered_out(128 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, recovered_out.data(), 128) == MUSE_OK);
  const float expected_v1_center =
      0.3f * dsp::computeConstantPowerPan(kCenterPan).left;
  CHECK_THAT(recovered_out[16 * 2 + 0],
             Catch::Matchers::WithinAbs(expected_v1_center, 1e-4f));
  CHECK_THAT(recovered_out[16 * 2 + 1],
             Catch::Matchers::WithinAbs(expected_v1_center, 1e-4f));
  REQUIRE(core.drainTelemetry(&tf, 1) == 1);
  CHECK(tf.take_playback_underrun == 0);
}

TEST_CASE("ButlerWorker resumes paused prefetch after ring saturation clears while HAL runs",
          "[butler_worker]") {
  const auto wav_path =
      std::filesystem::temp_directory_path() / "muse_paused_sat_take.wav";
  TempFileGuard wav_guard{wav_path};
  writeMonoF32Wav(wav_path, 48000, std::vector<float>(2048, 0.4f));

  MockHalState hal_state{};
  hal_state.config = stereoConfig(48000, 2);
  g_butler_mock_hal = &hal_state;
  struct MockHalResetGuard {
    ~MockHalResetGuard() { g_butler_mock_hal = nullptr; }
  } hal_reset_guard;
  const IPlatformAudioHal mock_hal{
      mockHalInit,
      mockHalStart,
      mockHalStop,
      mockHalDispose,
  };

  auto core_storage = std::make_unique<AudioEngineCore>();
  auto& core = *core_storage;
  MuseHardwareConfig out_cfg{};
  REQUIRE(core.initializeWithHal(mock_hal, &hal_state, &out_cfg) == MUSE_OK);
  REQUIRE(core.isHalRunning());
  REQUIRE(hal_state.last_callback != nullptr);

  // Saturate TakePlaybackRingBuffer with stale frames before registering take.
  constexpr uint32_t kStaleBatchFrames = 4096;
  const std::vector<float> stale_pcm(kStaleBatchFrames * kStereoChannelCount,
                                     0.9f);
  for (size_t offset = 0; offset < kTakePlaybackRingCapacityFrames;
       offset += kStaleBatchFrames) {
    uint32_t pushed = 0;
    REQUIRE(core.pushTakePlaybackPcm(0, static_cast<int64_t>(offset),
                                     stale_pcm.data(), kStaleBatchFrames,
                                     &pushed) == MUSE_OK);
    REQUIRE(pushed == kStaleBatchFrames);
  }
  REQUIRE(core.takePlaybackReadAvailable() == kTakePlaybackRingCapacityFrames);

  // Register active take while paused and HAL is running: ring stays full until
  // the next RT startCycle() drains stale invalidated frames.
  REQUIRE(core.registerActiveTake("paused_sat", wav_path.string().c_str(), 0,
                                  2048, 0.0f, kCenterPan) == MUSE_OK);
  std::this_thread::sleep_for(std::chrono::milliseconds(15));

  // Trigger a single paused RT callback so startCycle() discards stale frames.
  std::vector<float> paused_out(64 * kStereoChannelCount, 0.0f);
  hal_state.last_callback(hal_state.last_user_data, nullptr, paused_out.data(),
                          64);

  // ButlerWorker must resume paused prefetch via prefetch_incomplete_ without
  // needing play or seek.
  const auto deadline =
      std::chrono::steady_clock::now() + std::chrono::milliseconds(500);
  while (core.takePlaybackReadAvailable() < 1024 &&
         std::chrono::steady_clock::now() < deadline) {
    std::this_thread::sleep_for(std::chrono::milliseconds(2));
  }
  REQUIRE(core.takePlaybackReadAvailable() >= 1024);

  MutationCommand play_cmd{};
  play_cmd.type = MUT_SET_PLAYING;
  play_cmd.flag_a = 1;
  REQUIRE(core.pushMutation(play_cmd) == MUSE_OK);

  std::vector<float> play_out(128 * kStereoChannelCount, 0.0f);
  hal_state.last_callback(hal_state.last_user_data, nullptr, play_out.data(),
                          128);
  const float expected_center =
      0.4f * dsp::computeConstantPowerPan(kCenterPan).left;
  CHECK_THAT(play_out[16 * 2 + 0],
             Catch::Matchers::WithinAbs(expected_center, 1e-4f));
  CHECK_THAT(play_out[16 * 2 + 1],
             Catch::Matchers::WithinAbs(expected_center, 1e-4f));

  TelemetryFrame tf{};
  while (core.drainTelemetry(&tf, 1) == 1) {
    CHECK(tf.take_playback_underrun == 0);
  }

  core.dispose();
}
