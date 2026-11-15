#include <catch2/catch_test_macros.hpp>

#include <cmath>
#include <cstddef>
#include <cstdint>
#include <limits>
#include <thread>
#include <vector>

#include "engine_constants.h"
#include "hal_contract.h"
#include "infra/rt_pods.h"
#include "infra/spsc_queue.h"
#include "muse_engine_c_api.h"

using muse::engine::AuditionQueue;
using muse::engine::CaptureRingBuffer;
using muse::engine::EventQueue;
using muse::engine::MutationQueue;
using muse::engine::SpscRingBuffer;
using muse::engine::TakePlaybackRingBuffer;
using muse::engine::TelemetryQueue;
namespace dsp = muse::engine::dsp;

TEST_CASE("POD boundary structs preserve ABI sizes, alignment, and trivial copyability", "[pods][abi]") {
  REQUIRE(std::is_trivially_copyable_v<MuseHardwareConfig>);
  REQUIRE(sizeof(MuseHardwareConfig) == 148);
  REQUIRE(offsetof(MuseHardwareConfig, sample_rate) == 0);
  REQUIRE(offsetof(MuseHardwareConfig, input_channels) == 4);
  REQUIRE(offsetof(MuseHardwareConfig, output_channels) == 8);
  REQUIRE(offsetof(MuseHardwareConfig, input_buffer_frames) == 12);
  REQUIRE(offsetof(MuseHardwareConfig, output_buffer_frames) == 16);
  REQUIRE(offsetof(MuseHardwareConfig, device_fingerprint) == 20);

  REQUIRE(std::is_trivially_copyable_v<MutationCommand>);
  REQUIRE(sizeof(MutationCommand) == 48);
  REQUIRE(offsetof(MutationCommand, type) == 0);
  REQUIRE(offsetof(MutationCommand, channel) == 1);
  REQUIRE(offsetof(MutationCommand, flag_a) == 2);
  REQUIRE(offsetof(MutationCommand, reserved) == 3);
  REQUIRE(offsetof(MutationCommand, int_param_a) == 4);
  REQUIRE(offsetof(MutationCommand, int_param_b) == 8);
  REQUIRE(offsetof(MutationCommand, int_param_c) == 12);
  REQUIRE(offsetof(MutationCommand, float_param_a) == 16);
  REQUIRE(offsetof(MutationCommand, float_param_b) == 20);
  REQUIRE(offsetof(MutationCommand, target_epoch) == 24);
  REQUIRE(offsetof(MutationCommand, sample_frame_a) == 32);
  REQUIRE(offsetof(MutationCommand, sample_frame_b) == 40);

  REQUIRE(std::is_trivially_copyable_v<SynthNoteEvent>);
  REQUIRE(sizeof(SynthNoteEvent) == 24);
  REQUIRE(offsetof(SynthNoteEvent, epoch) == 0);
  REQUIRE(offsetof(SynthNoteEvent, target_sample_frame) == 8);
  REQUIRE(offsetof(SynthNoteEvent, type) == 16);
  REQUIRE(offsetof(SynthNoteEvent, channel) == 17);
  REQUIRE(offsetof(SynthNoteEvent, key_or_cc) == 18);
  REQUIRE(offsetof(SynthNoteEvent, velocity_or_val) == 19);
  REQUIRE(offsetof(SynthNoteEvent, pitch_bend) == 20);
  REQUIRE(offsetof(SynthNoteEvent, reserved) == 22);

  REQUIRE(std::is_trivially_copyable_v<TakePlaybackStereoFrame>);
  REQUIRE(sizeof(TakePlaybackStereoFrame) == 24);
  REQUIRE(offsetof(TakePlaybackStereoFrame, epoch) == 0);
  REQUIRE(offsetof(TakePlaybackStereoFrame, target_sample_frame) == 8);
  REQUIRE(offsetof(TakePlaybackStereoFrame, left) == 16);
  REQUIRE(offsetof(TakePlaybackStereoFrame, right) == 20);

  REQUIRE(std::is_trivially_copyable_v<TelemetryFrame>);
  REQUIRE(sizeof(TelemetryFrame) == 48);
  REQUIRE(offsetof(TelemetryFrame, playhead_sample_frame) == 0);
  REQUIRE(offsetof(TelemetryFrame, active_epoch) == 8);
  REQUIRE(offsetof(TelemetryFrame, output_peak_l) == 16);
  REQUIRE(offsetof(TelemetryFrame, output_peak_r) == 20);
  REQUIRE(offsetof(TelemetryFrame, output_rms_l) == 24);
  REQUIRE(offsetof(TelemetryFrame, output_rms_r) == 28);
  REQUIRE(offsetof(TelemetryFrame, input_peak) == 32);
  REQUIRE(offsetof(TelemetryFrame, input_rms) == 36);
  REQUIRE(offsetof(TelemetryFrame, is_playing) == 40);
  REQUIRE(offsetof(TelemetryFrame, is_capturing) == 41);
  REQUIRE(offsetof(TelemetryFrame, event_queue_underrun) == 42);
  REQUIRE(offsetof(TelemetryFrame, capture_buffer_overflow) == 43);
  REQUIRE(offsetof(TelemetryFrame, take_playback_underrun) == 44);
  REQUIRE(offsetof(TelemetryFrame, reserved) == 45);

  REQUIRE(std::is_trivially_copyable_v<FinalizedCaptureReceipt>);
  REQUIRE(sizeof(FinalizedCaptureReceipt) == 632);
  REQUIRE(offsetof(FinalizedCaptureReceipt, status) == 0);
  REQUIRE(offsetof(FinalizedCaptureReceipt, reserved_pad0) == 4);
  REQUIRE(offsetof(FinalizedCaptureReceipt, captured_sample_clock) == 8);
  REQUIRE(offsetof(FinalizedCaptureReceipt, captured_playhead_frame) == 16);
  REQUIRE(offsetof(FinalizedCaptureReceipt, duration_frames) == 24);
  REQUIRE(offsetof(FinalizedCaptureReceipt, sample_rate) == 32);
  REQUIRE(offsetof(FinalizedCaptureReceipt, channel_count) == 36);
  REQUIRE(offsetof(FinalizedCaptureReceipt, reserved) == 38);
  REQUIRE(offsetof(FinalizedCaptureReceipt, output_buffer_frames) == 40);
  REQUIRE(offsetof(FinalizedCaptureReceipt, input_buffer_frames) == 44);
  REQUIRE(offsetof(FinalizedCaptureReceipt, staging_path) == 48);
  REQUIRE(offsetof(FinalizedCaptureReceipt, sha256_hex) == 560);
  REQUIRE(offsetof(FinalizedCaptureReceipt, reserved_pad1) == 625);

  REQUIRE(std::is_trivially_copyable_v<MuseSoundFontPresetPod>);
  REQUIRE(sizeof(MuseSoundFontPresetPod) == 72);
  REQUIRE(offsetof(MuseSoundFontPresetPod, bank_num) == 0);
  REQUIRE(offsetof(MuseSoundFontPresetPod, program_num) == 4);
  REQUIRE(offsetof(MuseSoundFontPresetPod, preset_name) == 8);

  REQUIRE(MUSE_OK == 0);
  REQUIRE(MUSE_ERR_DEVICE_INIT == -1);
  REQUIRE(MUSE_ERR_PERMISSION_DENIED == -2);
  REQUIRE(MUSE_ERR_SF_LOAD_FAILED == -3);
  REQUIRE(MUSE_ERR_SF_TOO_LARGE == -4);
  REQUIRE(MUSE_ERR_TRANSPORT_NOT_STOPPED == -5);
  REQUIRE(MUSE_ERR_QUEUE_FULL == -6);
  REQUIRE(MUSE_ERR_CAPTURE_OVERFLOW == -7);
  REQUIRE(MUSE_ERR_STORAGE_IO == -8);
  REQUIRE(MUSE_ERR_BUFFER_TOO_SMALL == -9);
  REQUIRE(MUSE_ERR_TAKE_LOAD_FAILED == -10);

  REQUIRE(MUT_SET_PLAYING == 1);
  REQUIRE(MUT_SEEK_SAMPLE == 2);
  REQUIRE(MUT_SET_LOOP_REGION == 3);
  REQUIRE(MUT_FLUSH_AND_ADVANCE_EPOCH == 4);
  REQUIRE(MUT_ASSIGN_CHANNEL_PATCH == 5);
  REQUIRE(MUT_SET_CHANNEL_MIX == 6);
  REQUIRE(MUT_ALL_NOTES_OFF_CHANNEL == 7);
  REQUIRE(MUT_SET_MONITOR_GAIN == 8);
  REQUIRE(MUT_SET_CAPTURE_STATE == 9);
  REQUIRE(MUT_SET_SYNTH_SUSPENDED == 10);
  REQUIRE(MUT_SET_SCHEDULED_WATERMARK == 11);

  REQUIRE(EVT_NOTE_ON == 1);
  REQUIRE(EVT_NOTE_OFF == 2);
  REQUIRE(EVT_CONTROL_CHANGE == 3);
  REQUIRE(EVT_PITCH_BEND == 4);

  // Verify pre-allocated queue aliases satisfy power-of-two capacity bounds.
  REQUIRE(MutationQueue::capacity() == kMutationQueueCapacity);
  REQUIRE(EventQueue::capacity() == kEventQueueCapacity);
  REQUIRE(AuditionQueue::capacity() == kAuditionQueueCapacity);
  REQUIRE(CaptureRingBuffer::capacity() == kCaptureRingCapacityFrames * kMaxCaptureChannels);
  REQUIRE(TakePlaybackRingBuffer::capacity() == kTakePlaybackRingCapacityFrames);
  REQUIRE(TelemetryQueue::capacity() == kTelemetryQueueCapacity);
}

TEST_CASE("SpscRingBuffer handles saturation, peek/consume, wrap-around, and batches", "[spsc]") {
  constexpr size_t kCap = 8;
  SpscRingBuffer<int32_t, kCap> ring;

  REQUIRE(ring.empty());
  REQUIRE_FALSE(ring.full());
  REQUIRE(ring.readAvailable() == 0);
  REQUIRE(ring.writeAvailable() == kCap);
  REQUIRE(ring.peek() == nullptr);

  int32_t out = -1;
  REQUIRE_FALSE(ring.tryPop(out));

  // Fill to exact Capacity (no wasted sentinel slot).
  for (int32_t i = 0; i < static_cast<int32_t>(kCap); ++i) {
    REQUIRE(ring.tryPush(i + 100));
  }
  REQUIRE(ring.full());
  REQUIRE(ring.readAvailable() == kCap);
  REQUIRE(ring.writeAvailable() == 0);

  // Capacity + 1 must fail without overwriting head.
  REQUIRE_FALSE(ring.tryPush(999));
  REQUIRE(ring.peek() != nullptr);
  REQUIRE(*ring.peek() == 100);

  // Consume via peek + consumeOne and tryPop.
  ring.consumeOne();
  REQUIRE(ring.readAvailable() == kCap - 1);
  REQUIRE(ring.writeAvailable() == 1);
  REQUIRE(ring.tryPop(out));
  REQUIRE(out == 101);

  // Wrap-around across > 3 * Capacity single push/pop cycles.
  int32_t next_write = static_cast<int32_t>(100 + kCap);
  int32_t expected_read = 102;
  for (size_t i = 0; i < kCap * 4; ++i) {
    REQUIRE(ring.tryPush(next_write++));
    REQUIRE(ring.tryPop(out));
    REQUIRE(out == expected_read++);
  }

  // Drain remainder.
  while (!ring.empty()) {
    REQUIRE(ring.tryPop(out));
    REQUIRE(out == expected_read++);
  }
  REQUIRE(ring.empty());

  // Batch push & batch pop spanning wrap boundary.
  const std::vector<int32_t> batch_a = {1, 2, 3, 4, 5};
  REQUIRE(ring.tryPushBatch(batch_a.data(), batch_a.size()) == 5);
  std::vector<int32_t> pop_a(3, 0);
  REQUIRE(ring.tryPopBatch(pop_a.data(), pop_a.size()) == 3);
  REQUIRE(pop_a == std::vector<int32_t>{1, 2, 3});

  // 2 items remain; 6 free slots wrap across physical end of buffer.
  const std::vector<int32_t> batch_b = {6, 7, 8, 9, 10, 11, 12};
  REQUIRE(ring.tryPushBatch(batch_b.data(), batch_b.size()) == 6);
  REQUIRE(ring.full());

  std::vector<int32_t> pop_all(10, 0);
  REQUIRE(ring.tryPopBatch(pop_all.data(), pop_all.size()) == kCap);
  REQUIRE(std::vector<int32_t>(pop_all.begin(), pop_all.begin() + 8) ==
          std::vector<int32_t>{4, 5, 6, 7, 8, 9, 10, 11});
  REQUIRE(ring.empty());

  REQUIRE(ring.tryPush(42));
  ring.reset();
  REQUIRE(ring.empty());
  REQUIRE(ring.peek() == nullptr);

  // O(1) consumeUpToIndex discards stale prefix and clamps at writeIndex().
  const std::vector<int32_t> batch_c = {10, 20, 30, 40, 50};
  REQUIRE(ring.tryPushBatch(batch_c.data(), batch_c.size()) == 5);
  const size_t w_idx = ring.writeIndex();
  REQUIRE(w_idx == 5);
  ring.consumeUpToIndex(2);
  REQUIRE(ring.readAvailable() == 3);
  REQUIRE(*ring.peek() == 30);
  // Smaller index must not move consumer cursor backwards.
  ring.consumeUpToIndex(1);
  REQUIRE(ring.readAvailable() == 3);
  REQUIRE(*ring.peek() == 30);
  // Target past writeIndex() clamps cleanly without over-advancing.
  ring.consumeUpToIndex(w_idx + 100);
  REQUIRE(ring.empty());
  REQUIRE(ring.tryPush(77));
  REQUIRE(ring.tryPop(out));
  REQUIRE(out == 77);
}

TEST_CASE("SpscRingBuffer maintains FIFO integrity across concurrent threads", "[spsc][concurrent]") {
  constexpr uint64_t kTotalFrames = 100000;
  SpscRingBuffer<TakePlaybackStereoFrame, 1024> ring;

  std::thread producer([&]() {
    for (uint64_t i = 0; i < kTotalFrames; ++i) {
      const TakePlaybackStereoFrame frame{
          i + 1,
          static_cast<int64_t>(i * 3),
          static_cast<float>(i % 97),
          static_cast<float>((i * 2) % 89),
      };
      while (!ring.tryPush(frame)) {
        std::this_thread::yield();
      }
    }
  });

  std::thread consumer([&]() {
    TakePlaybackStereoFrame out{};
    for (uint64_t i = 0; i < kTotalFrames; ++i) {
      while (!ring.tryPop(out)) {
        std::this_thread::yield();
      }
      REQUIRE(out.epoch == i + 1);
      REQUIRE(out.target_sample_frame == static_cast<int64_t>(i * 3));
      REQUIRE(out.left == static_cast<float>(i % 97));
      REQUIRE(out.right == static_cast<float>((i * 2) % 89));
    }
  });

  producer.join();
  consumer.join();
  REQUIRE(ring.empty());
}

TEST_CASE("Centralized C++ DSP math helpers satisfy dB, pan, folddown, and limiter invariants", "[dsp]") {
  // dB to linear gain
  REQUIRE(dsp::dbToLinear(kDefaultGainDb) == 1.0f);
  const float boost_6db = dsp::dbToLinear(6.0f);
  const float cut_6db = dsp::dbToLinear(-6.0f);
  REQUIRE(std::fabs(boost_6db * cut_6db - 1.0f) < 1e-6f);
  REQUIRE(boost_6db > 1.99f);
  REQUIRE(boost_6db < 2.0f);
  REQUIRE(dsp::dbToLinear(1000.0f) == dsp::dbToLinear(kMaxDbGainClamp));
  REQUIRE(dsp::dbToLinear(-1000.0f) == dsp::dbToLinear(kMinDbGainClamp));
  REQUIRE(dsp::dbToLinear(std::numeric_limits<float>::quiet_NaN()) == 0.0f);

  // Constant-power stereo pan
  const auto center = dsp::computeConstantPowerPan(kCenterPan);
  REQUIRE(std::fabs(center.left - center.right) < 1e-6f);
  REQUIRE(std::fabs(center.left * center.left + center.right * center.right - 1.0f) < 1e-6f);

  const auto hard_left = dsp::computeConstantPowerPan(kMinPan);
  REQUIRE(std::fabs(hard_left.left - 1.0f) < 1e-6f);
  REQUIRE(hard_left.right >= 0.0f);
  REQUIRE(hard_left.right <= 1e-6f);

  const auto hard_right = dsp::computeConstantPowerPan(kMaxPan);
  REQUIRE(hard_right.left >= 0.0f);
  REQUIRE(hard_right.left <= 1e-6f);
  REQUIRE(std::fabs(hard_right.right - 1.0f) < 1e-6f);

  // Unity power preservation across sweep
  for (int step = -10; step <= 10; ++step) {
    const float pan = static_cast<float>(step) / 10.0f;
    const auto gains = dsp::computeConstantPowerPan(pan);
    REQUIRE(gains.left >= 0.0f);
    REQUIRE(gains.right >= 0.0f);
    REQUIRE(std::fabs(gains.left * gains.left + gains.right * gains.right - 1.0f) < 1e-5f);
  }

  // Mono folddown
  REQUIRE(std::fabs(dsp::foldStereoToMono(0.6f, -0.2f) - 0.2f) < 1e-6f);

  // Soft-knee brickwall limiter
  REQUIRE(dsp::applySoftLimiter(0.5f) == 0.5f);
  REQUIRE(dsp::applySoftLimiter(-0.5f) == -0.5f);
  REQUIRE(dsp::applySoftLimiter(kLimiterSoftKneeThreshold) == kLimiterSoftKneeThreshold);

  const float over_pos = dsp::applySoftLimiter(10.0f);
  const float over_neg = dsp::applySoftLimiter(-10.0f);
  REQUIRE(over_pos > kLimiterSoftKneeThreshold);
  REQUIRE(over_pos <= kLimiterCeiling);
  REQUIRE(over_neg < -kLimiterSoftKneeThreshold);
  REQUIRE(over_neg >= -kLimiterCeiling);
  REQUIRE(std::fabs(over_pos + over_neg) < 1e-6f);
  REQUIRE(dsp::applySoftLimiter(1.0e12f) <= kLimiterCeiling);

  // Monotonicity check across knee & saturation region
  float prev = dsp::applySoftLimiter(-20.0f);
  for (int i = -199; i <= 200; ++i) {
    const float cur = dsp::applySoftLimiter(static_cast<float>(i) * 0.1f);
    REQUIRE(cur > prev);
    prev = cur;
  }

  // Non-finite sanitization
  REQUIRE(dsp::applySoftLimiter(std::numeric_limits<float>::quiet_NaN()) == 0.0f);
  REQUIRE(dsp::applySoftLimiter(std::numeric_limits<float>::infinity()) == 0.0f);
  REQUIRE(dsp::applySoftLimiter(-std::numeric_limits<float>::infinity()) == 0.0f);
}
