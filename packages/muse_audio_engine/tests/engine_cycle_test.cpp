#include <catch2/catch_test_macros.hpp>
#include <catch2/matchers/catch_matchers_floating_point.hpp>

#include <algorithm>
#include <array>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <limits>
#include <vector>

#include "audio_engine_core.h"

namespace {

using namespace muse::engine;

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

void appendFourCc(std::vector<uint8_t>& out, const char (&fcc)[5]) {
  out.insert(out.end(), fcc, fcc + 4);
}

void appendFixedStr(std::vector<uint8_t>& out, const char* str, size_t width) {
  std::vector<uint8_t> buf(width, 0);
  if (str != nullptr) {
    const size_t len = std::min(width - 1, std::strlen(str));
    std::memcpy(buf.data(), str, len);
  }
  out.insert(out.end(), buf.begin(), buf.end());
}

void writeU32At(std::vector<uint8_t>& out, size_t offset, uint32_t v) {
  out[offset + 0] = static_cast<uint8_t>(v & 0xFFu);
  out[offset + 1] = static_cast<uint8_t>((v >> 8) & 0xFFu);
  out[offset + 2] = static_cast<uint8_t>((v >> 16) & 0xFFu);
  out[offset + 3] = static_cast<uint8_t>((v >> 24) & 0xFFu);
}

// Builds a minimal valid SoundFont 2.01 RIFF payload with 1 looped sine preset
// (Bank 0, Program 0) in memory so FluidSynth tests need no external .sf2 disk asset.
std::vector<uint8_t> buildMinimalTestSf2Bytes() {
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
  appendFixedStr(sf, "MuseTst", 8);

  writeU32At(sf, info_size_off,
             static_cast<uint32_t>(sf.size() - info_size_off - 4));

  // 2. sdta LIST (100-sample looped 480 Hz sine wave + trailing zero padding)
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
  appendFixedStr(sf, "TestSine", 20);
  appendU16(sf, 0);
  appendU16(sf, 0);
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

  // pbag (2 * 4 bytes)
  appendFourCc(sf, "pbag");
  appendU32(sf, 8);
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 1);
  appendU16(sf, 0);

  // pmod (1 * 10 bytes terminator)
  appendFourCc(sf, "pmod");
  appendU32(sf, 10);
  for (int i = 0; i < 5; ++i) {
    appendU16(sf, 0);
  }

  // pgen (2 * 4 bytes: instrument=0 + terminal)
  appendFourCc(sf, "pgen");
  appendU32(sf, 8);
  appendU16(sf, 41); // sfGenOper instrument
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 0);

  // inst (2 * 22 bytes)
  appendFourCc(sf, "inst");
  appendU32(sf, 44);
  appendFixedStr(sf, "SineInst", 20);
  appendU16(sf, 0);
  appendFixedStr(sf, "EOI", 20);
  appendU16(sf, 1);

  // ibag (2 * 4 bytes: 2 gens + terminal)
  appendFourCc(sf, "ibag");
  appendU32(sf, 8);
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 2);
  appendU16(sf, 0);

  // imod (1 * 10 bytes terminator)
  appendFourCc(sf, "imod");
  appendU32(sf, 10);
  for (int i = 0; i < 5; ++i) {
    appendU16(sf, 0);
  }

  // igen (3 * 4 bytes: sampleModes=1 (loop), sampleID=0, terminal)
  appendFourCc(sf, "igen");
  appendU32(sf, 12);
  appendU16(sf, 54); // sampleModes
  appendU16(sf, 1);  // continuous loop
  appendU16(sf, 53); // sampleID
  appendU16(sf, 0);
  appendU16(sf, 0);
  appendU16(sf, 0);

  // shdr (2 * 46 bytes)
  appendFourCc(sf, "shdr");
  appendU32(sf, 92);
  appendFixedStr(sf, "SineWave", 20);
  appendU32(sf, kLoopStart);
  appendU32(sf, kLoopEnd + 16);
  appendU32(sf, kLoopStart);
  appendU32(sf, kLoopEnd);
  appendU32(sf, 48000);
  sf.push_back(60); // middle C
  sf.push_back(0);  // correction
  appendU16(sf, 0); // link
  appendU16(sf, 1); // monoSample

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

MuseHardwareConfig defaultStereoConfig(uint32_t input_ch = 2) {
  MuseHardwareConfig cfg{};
  cfg.sample_rate = 48000;
  cfg.input_channels = input_ch;
  cfg.output_channels = 2;
  cfg.input_buffer_frames = 512;
  cfg.output_buffer_frames = 512;
  std::snprintf(cfg.device_fingerprint, sizeof(cfg.device_fingerprint),
                "test-stereo");
  return cfg;
}

float maxAbsRange(
    const std::vector<float>& interleaved,
    size_t start_frame,
    size_t end_frame,
    uint32_t channels) {
  float peak = 0.0f;
  for (size_t f = start_frame; f < end_frame; ++f) {
    for (uint32_t ch = 0; ch < channels; ++ch) {
      peak = std::max(peak, std::fabs(interleaved[f * channels + ch]));
    }
  }
  return peak;
}

float channelPeak(
    const std::vector<float>& interleaved,
    uint32_t ch_idx,
    uint32_t channels) {
  float peak = 0.0f;
  const size_t frames = interleaved.size() / channels;
  for (size_t f = 0; f < frames; ++f) {
    peak = std::max(peak, std::fabs(interleaved[f * channels + ch_idx]));
  }
  return peak;
}

int32_t loadTestSf2(AudioEngineCore& core) {
  const auto sf_bytes = buildMinimalTestSf2Bytes();
  int32_t sf_id = kFluidSynthSfFailed;
  std::array<MuseSoundFontPresetPod, 8> presets{};
  uint32_t preset_count = 0;
  const MuseStatus st = core.loadSoundFontBytes(
      sf_bytes.data(), static_cast<uint32_t>(sf_bytes.size()), &sf_id,
      presets.data(), static_cast<uint32_t>(presets.size()), &preset_count);
  REQUIRE(st == MUSE_OK);
  REQUIRE(sf_id > 0);
  REQUIRE(preset_count == 1);
  return sf_id;
}

void pushSimpleMutation(AudioEngineCore& core, const MutationCommand& cmd) {
  REQUIRE(core.pushMutation(cmd) == MUSE_OK);
}

void assignPatch(AudioEngineCore& core, uint8_t ch, int32_t sf_id) {
  MutationCommand patch{};
  patch.type = MUT_ASSIGN_CHANNEL_PATCH;
  patch.channel = ch;
  patch.int_param_a = sf_id;
  patch.int_param_b = 0;
  patch.int_param_c = 0;
  pushSimpleMutation(core, patch);
}

} // namespace

TEST_CASE("Three-phase cycle splits sub-block MIDI timing and emits telemetry",
          "[engine_cycle]") {
  AudioEngineCore core;
  REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);
  const int32_t sf_id = loadTestSf2(core);
  assignPatch(core, 0, sf_id);

  MutationCommand play{};
  play.type = MUT_SET_PLAYING;
  play.flag_a = 1;
  pushSimpleMutation(core, play);

  SynthNoteEvent note{};
  note.epoch = 0;
  note.target_sample_frame = 256;
  note.type = EVT_NOTE_ON;
  note.channel = 0;
  note.key_or_cc = 60;
  note.velocity_or_val = 100;
  uint32_t pushed = 0;
  REQUIRE(core.pushEvents(&note, 1, &pushed) == MUSE_OK);
  REQUIRE(pushed == 1);

  std::vector<float> out(512 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, out.data(), 512) == MUSE_OK);

  CHECK(maxAbsRange(out, 0, 256, 2) == 0.0f);
  CHECK(maxAbsRange(out, 256, 512, 2) > 0.01f);
  CHECK(core.playheadAtomic() == 512);

  TelemetryFrame tf{};
  REQUIRE(core.drainTelemetry(&tf, 1) == 1);
  CHECK(tf.playhead_sample_frame == 0);
  CHECK(tf.is_playing == 1);
  CHECK(tf.output_peak_l > 0.01f);

  std::vector<float> out2(512 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, out2.data(), 512) == MUSE_OK);
  TelemetryFrame tf2{};
  REQUIRE(core.drainTelemetry(&tf2, 1) == 1);
  CHECK(tf2.playhead_sample_frame == 512);
  CHECK(core.playheadAtomic() == 1024);
}

TEST_CASE("MUT_FLUSH_AND_ADVANCE_EPOCH discards stale epochs and keeps new ones",
          "[engine_cycle]") {
  AudioEngineCore core;
  REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);
  const int32_t sf_id = loadTestSf2(core);
  assignPatch(core, 0, sf_id);

  MutationCommand play{};
  play.type = MUT_SET_PLAYING;
  play.flag_a = 1;
  pushSimpleMutation(core, play);

  SynthNoteEvent stale_note{};
  stale_note.epoch = 1;
  stale_note.target_sample_frame = 0;
  stale_note.type = EVT_NOTE_ON;
  stale_note.channel = 0;
  stale_note.key_or_cc = 60;
  stale_note.velocity_or_val = 110;

  SynthNoteEvent fresh_note = stale_note;
  fresh_note.epoch = 2;
  fresh_note.target_sample_frame = 512;

  SynthNoteEvent batch[2] = {stale_note, fresh_note};
  uint32_t pushed = 0;
  REQUIRE(core.pushEvents(batch, 2, &pushed) == MUSE_OK);
  REQUIRE(pushed == 2);

  MutationCommand flush{};
  flush.type = MUT_FLUSH_AND_ADVANCE_EPOCH;
  flush.target_epoch = 2;
  pushSimpleMutation(core, flush);

  std::vector<float> out1(512 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, out1.data(), 512) == MUSE_OK);
  CHECK(maxAbsRange(out1, 0, 512, 2) == 0.0f);
  CHECK(core.activeEpochAtomic() == 2);

  std::vector<float> out2(512 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, out2.data(), 512) == MUSE_OK);
  CHECK(maxAbsRange(out2, 0, 512, 2) > 0.01f);
}

TEST_CASE("Live audition bypasses queued paused events without triggering panic storms",
          "[engine_cycle]") {
  AudioEngineCore core;
  REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);
  const int32_t sf_id = loadTestSf2(core);
  assignPatch(core, 0, sf_id);

  SynthNoteEvent paused_future{};
  paused_future.epoch = 0;
  paused_future.target_sample_frame = 2000;
  paused_future.type = EVT_NOTE_ON;
  paused_future.channel = 0;
  paused_future.key_or_cc = 64;
  paused_future.velocity_or_val = 100;

  SynthNoteEvent audition{};
  audition.epoch = 0;
  audition.target_sample_frame = kImmediateDispatchFrame;
  audition.type = EVT_NOTE_ON;
  audition.channel = 0;
  audition.key_or_cc = 60;
  audition.velocity_or_val = 100;

  SynthNoteEvent events[2] = {paused_future, audition};
  uint32_t pushed = 0;
  REQUIRE(core.pushEvents(events, 2, &pushed) == MUSE_OK);
  REQUIRE(pushed == 2);

  std::vector<float> block1(512 * 2, 0.0f);
  std::vector<float> block2(512 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, block1.data(), 512) == MUSE_OK);
  REQUIRE(core.processBlock(nullptr, block2.data(), 512) == MUSE_OK);

  // Audition must play cleanly across paused blocks with playhead fixed at 0.
  CHECK(maxAbsRange(block1, 0, 512, 2) > 0.01f);
  CHECK(maxAbsRange(block2, 0, 512, 2) > 0.01f);
  CHECK(core.playheadAtomic() == 0);

  // Silence audition note, seek to queued timeline note, and prove it stayed queued.
  MutationCommand panic{};
  panic.type = MUT_ALL_NOTES_OFF_CHANNEL;
  panic.channel = 0;
  pushSimpleMutation(core, panic);

  MutationCommand seek{};
  seek.type = MUT_SEEK_SAMPLE;
  seek.sample_frame_a = 2000;
  pushSimpleMutation(core, seek);

  MutationCommand play{};
  play.type = MUT_SET_PLAYING;
  play.flag_a = 1;
  pushSimpleMutation(core, play);

  std::vector<float> block3(256 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, block3.data(), 256) == MUSE_OK);
  CHECK(maxAbsRange(block3, 0, 256, 2) > 0.01f);
}

TEST_CASE("Loop-boundary sub-block split wraps playhead without altering epoch",
          "[engine_cycle]") {
  AudioEngineCore core;
  REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);

  MutationCommand loop{};
  loop.type = MUT_SET_LOOP_REGION;
  loop.flag_a = 1;
  loop.sample_frame_a = 100;
  loop.sample_frame_b = 300;
  pushSimpleMutation(core, loop);

  MutationCommand seek{};
  seek.type = MUT_SEEK_SAMPLE;
  seek.target_epoch = 1;
  seek.sample_frame_a = 200;
  pushSimpleMutation(core, seek);

  MutationCommand play{};
  play.type = MUT_SET_PLAYING;
  play.flag_a = 1;
  pushSimpleMutation(core, play);

  std::array<float, 2> pre_wrap_sample{0.25f, -0.25f};
  std::array<float, 2> post_wrap_sample{0.50f, -0.50f};
  uint32_t pushed = 0;
  REQUIRE(core.pushTakePlaybackPcm(1, 250, pre_wrap_sample.data(), 1, &pushed) ==
          MUSE_OK);
  REQUIRE(core.pushTakePlaybackPcm(1, 100, post_wrap_sample.data(), 1, &pushed) ==
          MUSE_OK);

  std::vector<float> out(256 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, out.data(), 256) == MUSE_OK);

  // Frame 50 corresponds to timeline 250; frame 100 corresponds to wrapped timeline 100.
  CHECK_THAT(out[50 * 2 + 0], Catch::Matchers::WithinAbs(0.25f, 1e-5f));
  CHECK_THAT(out[50 * 2 + 1], Catch::Matchers::WithinAbs(-0.25f, 1e-5f));
  CHECK_THAT(out[100 * 2 + 0], Catch::Matchers::WithinAbs(0.50f, 1e-5f));
  CHECK_THAT(out[100 * 2 + 1], Catch::Matchers::WithinAbs(-0.50f, 1e-5f));
  CHECK(core.playheadAtomic() == 256);
  CHECK(core.activeEpochAtomic() == 1);

  std::array<TelemetryFrame, 4> frames{};
  REQUIRE(core.drainTelemetry(frames.data(), 4) == 2);
  CHECK(frames[0].playhead_sample_frame == 200);
  CHECK(frames[1].playhead_sample_frame == 100);
  CHECK(frames[0].active_epoch == 1);
  CHECK(frames[1].active_epoch == 1);
}

TEST_CASE("Multi-bus MUT_SET_CHANNEL_MIX supports +6 dB boost and hard L/R isolation",
          "[engine_cycle]") {
  auto renderSoloChannel = [](uint8_t channel, float gain_db, float pan) {
    AudioEngineCore core;
    REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);
    const int32_t sf_id = loadTestSf2(core);
    assignPatch(core, channel, sf_id);

    MutationCommand mix{};
    mix.type = MUT_SET_CHANNEL_MIX;
    mix.channel = channel;
    mix.float_param_a = gain_db;
    mix.float_param_b = pan;
    pushSimpleMutation(core, mix);

    MutationCommand play{};
    play.type = MUT_SET_PLAYING;
    play.flag_a = 1;
    pushSimpleMutation(core, play);

    SynthNoteEvent evt{};
    evt.epoch = 0;
    evt.target_sample_frame = 0;
    evt.type = EVT_NOTE_ON;
    evt.channel = channel;
    evt.key_or_cc = 60;
    evt.velocity_or_val = 64;
    uint32_t pushed = 0;
    REQUIRE(core.pushEvents(&evt, 1, &pushed) == MUSE_OK);

    std::vector<float> out(512 * 2, 0.0f);
    REQUIRE(core.processBlock(nullptr, out.data(), 512) == MUSE_OK);
    return out;
  };

  const auto ch0_left_0db = renderSoloChannel(0, 0.0f, kMinPan);
  const float ch0_l = channelPeak(ch0_left_0db, 0, 2);
  const float ch0_r = channelPeak(ch0_left_0db, 1, 2);
  CHECK(ch0_l > 0.01f);
  CHECK(ch0_r == 0.0f);

  const auto ch1_right_boost = renderSoloChannel(1, 6.0205999f, kMaxPan);
  const float ch1_l = channelPeak(ch1_right_boost, 0, 2);
  const float ch1_r = channelPeak(ch1_right_boost, 1, 2);
  CHECK(ch1_l < 1e-6f);
  CHECK_THAT(ch1_r / ch0_l, Catch::Matchers::WithinAbs(2.0f, 0.05f));
}

TEST_CASE("TakePlaybackRingBuffer mixes takes and reports underrun only inside active windows",
          "[engine_cycle]") {
  AudioEngineCore core;
  REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);

  const TakeWindowRange window{128, 256, 1};
  core.updateTakeWindows(&window, 1);

  MutationCommand play{};
  play.type = MUT_SET_PLAYING;
  play.flag_a = 1;
  pushSimpleMutation(core, play);

  // Prepend stale epoch=0 frame at 128 that must be skipped, plus valid epoch=0
  // mismatch test by advancing epoch to 1 first.
  MutationCommand epoch_cmd{};
  epoch_cmd.type = MUT_FLUSH_AND_ADVANCE_EPOCH;
  epoch_cmd.target_epoch = 1;
  pushSimpleMutation(core, epoch_cmd);

  std::vector<float> stale_frame{0.9f, 0.9f};
  std::vector<float> valid_take(64 * 2);
  for (size_t i = 0; i < 64; ++i) {
    valid_take[i * 2 + 0] = 0.3f;
    valid_take[i * 2 + 1] = -0.3f;
  }
  uint32_t pushed = 0;
  REQUIRE(core.pushTakePlaybackPcm(0, 128, stale_frame.data(), 1, &pushed) ==
          MUSE_OK);
  REQUIRE(core.pushTakePlaybackPcm(1, 128, valid_take.data(), 64, &pushed) ==
          MUSE_OK);

  std::vector<float> out(64 * 2, 0.0f);
  TelemetryFrame tf{};

  // [0, 64) outside registered window [128, 256) -> zero underrun
  REQUIRE(core.processBlock(nullptr, out.data(), 64) == MUSE_OK);
  REQUIRE(core.drainTelemetry(&tf, 1) == 1);
  CHECK(tf.take_playback_underrun == 0);

  // [64, 128) outside window -> zero underrun
  REQUIRE(core.processBlock(nullptr, out.data(), 64) == MUSE_OK);
  REQUIRE(core.drainTelemetry(&tf, 1) == 1);
  CHECK(tf.take_playback_underrun == 0);

  // [128, 192) matched -> mixed cleanly, zero underrun
  REQUIRE(core.processBlock(nullptr, out.data(), 64) == MUSE_OK);
  REQUIRE(core.drainTelemetry(&tf, 1) == 1);
  CHECK(tf.take_playback_underrun == 0);
  CHECK_THAT(out[0], Catch::Matchers::WithinAbs(0.3f, 1e-5f));
  CHECK_THAT(out[1], Catch::Matchers::WithinAbs(-0.3f, 1e-5f));

  // [192, 256) inside registered window with empty buffer -> underrun flagged
  REQUIRE(core.processBlock(nullptr, out.data(), 64) == MUSE_OK);
  REQUIRE(core.drainTelemetry(&tf, 1) == 1);
  CHECK(tf.take_playback_underrun == 1);

  // Loop wrap discards pre-loop overread frames >= loop_end_frame
  core.clearTakeWindows();
  MutationCommand loop{};
  loop.type = MUT_SET_LOOP_REGION;
  loop.flag_a = 1;
  loop.sample_frame_a = 100;
  loop.sample_frame_b = 300;
  pushSimpleMutation(core, loop);

  MutationCommand seek{};
  seek.type = MUT_SEEK_SAMPLE;
  seek.target_epoch = 2;
  seek.sample_frame_a = 280;
  pushSimpleMutation(core, seek);

  std::vector<float> overread(4 * 2, 0.7f);
  std::vector<float> wrapped(2 * 2, 0.4f);
  REQUIRE(core.pushTakePlaybackPcm(2, 300, overread.data(), 4, &pushed) ==
          MUSE_OK);
  REQUIRE(core.pushTakePlaybackPcm(2, 100, wrapped.data(), 2, &pushed) ==
          MUSE_OK);

  std::vector<float> loop_out(24 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, loop_out.data(), 24) == MUSE_OK);
  // Pre-wrap took 20 frames [280..300), so sample index 20 is timeline 100.
  CHECK_THAT(loop_out[20 * 2 + 0], Catch::Matchers::WithinAbs(0.4f, 1e-5f));
  CHECK_THAT(loop_out[21 * 2 + 1], Catch::Matchers::WithinAbs(0.4f, 1e-5f));
}

TEST_CASE("Soft limiter, NaN sanitization, and CaptureRingBuffer fail-closed contracts",
          "[engine_cycle]") {
  SECTION("Soft limiter bounds extreme inputs and sanitizes NaNs") {
    CHECK(dsp::applySoftLimiter(std::numeric_limits<float>::quiet_NaN()) == 0.0f);
    CHECK(dsp::applySoftLimiter(std::numeric_limits<float>::infinity()) == 0.0f);
    const float limited_pos = dsp::applySoftLimiter(10.0f);
    const float limited_neg = dsp::applySoftLimiter(-10.0f);
    CHECK(limited_pos > kLimiterSoftKneeThreshold);
    CHECK(limited_pos <= kLimiterCeiling);
    CHECK(limited_neg >= -kLimiterCeiling);

    AudioEngineCore core;
    REQUIRE(core.initializeWithConfig(defaultStereoConfig(2)) == MUSE_OK);
    MutationCommand mon{};
    mon.type = MUT_SET_MONITOR_GAIN;
    mon.float_param_a = 2.0f;
    pushSimpleMutation(core, mon);

    std::vector<float> in(16 * 2, 5.0f);
    in[2] = std::numeric_limits<float>::quiet_NaN();
    std::vector<float> out(16 * 2, 0.0f);
    REQUIRE(core.processBlock(in.data(), out.data(), 16) == MUSE_OK);
    for (float s : out) {
      CHECK(std::isfinite(s));
      CHECK(std::fabs(s) <= kLimiterCeiling);
    }
    CHECK(out[2] == 0.0f);
    CHECK(out[0] > kLimiterSoftKneeThreshold);
  }

  SECTION("CaptureRingBuffer latches first clock and fails closed on overflow") {
    AudioEngineCore core;
    REQUIRE(core.initializeWithConfig(defaultStereoConfig(2)) == MUSE_OK);

    // Advance hardware clock by 256 frames before capture starts.
    std::vector<float> warmup_out(256 * 2, 0.0f);
    REQUIRE(core.processBlock(nullptr, warmup_out.data(), 256) == MUSE_OK);

    MutationCommand seek{};
    seek.type = MUT_SEEK_SAMPLE;
    seek.sample_frame_a = 1000;
    pushSimpleMutation(core, seek);

    MutationCommand arm_capture{};
    arm_capture.type = MUT_SET_CAPTURE_STATE;
    arm_capture.flag_a = 1;
    pushSimpleMutation(core, arm_capture);

    std::vector<float> mic(256 * 2, 0.25f);
    std::vector<float> out(256 * 2, 0.0f);
    REQUIRE(core.processBlock(mic.data(), out.data(), 256) == MUSE_OK);

    CHECK(core.captureLatch().clock_latched.load());
    CHECK(core.captureLatch().captured_sample_clock == 256);
    CHECK(core.captureLatch().captured_playhead_frame == 1000);

    std::vector<float> drained(256 * 2, 0.0f);
    int64_t first_clk = -1;
    REQUIRE(core.drainCaptureFrames(drained.data(), 256, &first_clk) == 256);
    CHECK(first_clk == 256);
    CHECK_THAT(drained[0], Catch::Matchers::WithinAbs(0.25f, 1e-6f));

    // Fill CaptureRingBuffer beyond kCaptureRingCapacityFrames (65536 stereo frames)
    std::vector<float> big_mic(4096 * 2, 0.1f);
    std::vector<float> big_out(4096 * 2, 0.0f);
    TelemetryFrame last_tf{};
    for (int b = 0; b < 18; ++b) {
      REQUIRE(core.processBlock(big_mic.data(), big_out.data(), 4096) == MUSE_OK);
      TelemetryFrame tmp{};
      while (core.drainTelemetry(&tmp, 1) == 1) {
        last_tf = tmp;
      }
    }
    CHECK(core.didCaptureOverflow());
    CHECK(!core.captureActiveAtomic());
    CHECK(last_tf.capture_buffer_overflow == 1);
  }

  SECTION("Playback-only device fails closed on prepareCapture and drainCaptureFrames") {
    AudioEngineCore core;
    REQUIRE(core.initializeWithConfig(defaultStereoConfig(0)) == MUSE_OK);
    CHECK(core.prepareCapture("/tmp/muse_no_mic.wav.part") == MUSE_ERR_DEVICE_INIT);
    std::array<float, 16> buf{};
    int64_t clk = 123;
    CHECK(core.drainCaptureFrames(buf.data(), 8, &clk) == 0);
    CHECK(clk == 0);
  }
}

TEST_CASE("Scheduled watermark underrun, persistent synth suspend, and capture latch re-arming",
          "[engine_cycle]") {
  SECTION("MUT_SET_SCHEDULED_WATERMARK flags event_queue_underrun only for exact active epoch") {
    AudioEngineCore core;
    REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);

    MutationCommand flush{};
    flush.type = MUT_FLUSH_AND_ADVANCE_EPOCH;
    flush.target_epoch = 2;
    pushSimpleMutation(core, flush);

    MutationCommand play{};
    play.type = MUT_SET_PLAYING;
    play.flag_a = 1;
    pushSimpleMutation(core, play);

    // Mismatched epochs (stale=1, future=3) must be ignored.
    MutationCommand wrong_future_wm{};
    wrong_future_wm.type = MUT_SET_SCHEDULED_WATERMARK;
    wrong_future_wm.target_epoch = 3;
    wrong_future_wm.sample_frame_a = 0;
    pushSimpleMutation(core, wrong_future_wm);

    MutationCommand wrong_stale_wm{};
    wrong_stale_wm.type = MUT_SET_SCHEDULED_WATERMARK;
    wrong_stale_wm.target_epoch = 1;
    wrong_stale_wm.sample_frame_a = 0;
    pushSimpleMutation(core, wrong_stale_wm);

    std::vector<float> out(128 * 2, 0.0f);
    REQUIRE(core.processBlock(nullptr, out.data(), 128) == MUSE_OK);
    TelemetryFrame tf{};
    REQUIRE(core.drainTelemetry(&tf, 1) == 1);
    CHECK(tf.event_queue_underrun == 0);

    // Active epoch=2 watermark at 256: [128, 256) is covered -> 0 underrun.
    MutationCommand active_wm{};
    active_wm.type = MUT_SET_SCHEDULED_WATERMARK;
    active_wm.target_epoch = 2;
    active_wm.sample_frame_a = 256;
    pushSimpleMutation(core, active_wm);

    REQUIRE(core.processBlock(nullptr, out.data(), 128) == MUSE_OK);
    REQUIRE(core.drainTelemetry(&tf, 1) == 1);
    CHECK(tf.event_queue_underrun == 0);

    // [256, 384) exceeds watermark 256 with empty EventQueue -> underrun = 1.
    REQUIRE(core.processBlock(nullptr, out.data(), 128) == MUSE_OK);
    REQUIRE(core.drainTelemetry(&tf, 1) == 1);
    CHECK(tf.event_queue_underrun == 1);
  }

  SECTION("MUT_SET_SYNTH_SUSPENDED persists across multiple processBlock cycles") {
    AudioEngineCore core;
    REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);
    const int32_t sf_id = loadTestSf2(core);
    assignPatch(core, 0, sf_id);

    SynthNoteEvent audition{};
    audition.epoch = 0;
    audition.target_sample_frame = kImmediateDispatchFrame;
    audition.type = EVT_NOTE_ON;
    audition.channel = 0;
    audition.key_or_cc = 60;
    audition.velocity_or_val = 100;
    uint32_t pushed = 0;
    REQUIRE(core.pushEvents(&audition, 1, &pushed) == MUSE_OK);

    std::vector<float> active_out(256 * 2, 0.0f);
    REQUIRE(core.processBlock(nullptr, active_out.data(), 256) == MUSE_OK);
    REQUIRE(maxAbsRange(active_out, 0, 256, 2) > 0.01f);

    MutationCommand suspend{};
    suspend.type = MUT_SET_SYNTH_SUSPENDED;
    suspend.flag_a = 1;
    pushSimpleMutation(core, suspend);

    for (int cycle = 0; cycle < 3; ++cycle) {
      std::vector<float> silent_out(256 * 2, 1.0f);
      REQUIRE(core.processBlock(nullptr, silent_out.data(), 256) == MUSE_OK);
      CHECK(maxAbsRange(silent_out, 0, 256, 2) == 0.0f);
    }

    MutationCommand resume{};
    resume.type = MUT_SET_SYNTH_SUSPENDED;
    resume.flag_a = 0;
    pushSimpleMutation(core, resume);

    std::vector<float> resumed_out(256 * 2, 0.0f);
    REQUIRE(core.processBlock(nullptr, resumed_out.data(), 256) == MUSE_OK);
    CHECK(maxAbsRange(resumed_out, 0, 256, 2) > 0.01f);
  }

  SECTION("MUT_SET_CAPTURE_STATE re-arms capture_latch_ across consecutive captures") {
    AudioEngineCore core;
    REQUIRE(core.initializeWithConfig(defaultStereoConfig(2)) == MUSE_OK);

    std::vector<float> warmup_out(128 * 2, 0.0f);
    REQUIRE(core.processBlock(nullptr, warmup_out.data(), 128) == MUSE_OK);

    MutationCommand seek1{};
    seek1.type = MUT_SEEK_SAMPLE;
    seek1.sample_frame_a = 500;
    pushSimpleMutation(core, seek1);

    MutationCommand arm{};
    arm.type = MUT_SET_CAPTURE_STATE;
    arm.flag_a = 1;
    pushSimpleMutation(core, arm);

    std::vector<float> mic1(64 * 2, 0.2f);
    std::vector<float> out(64 * 2, 0.0f);
    REQUIRE(core.processBlock(mic1.data(), out.data(), 64) == MUSE_OK);
    CHECK(core.captureLatch().clock_latched.load());
    CHECK(core.captureLatch().captured_sample_clock == 128);
    CHECK(core.captureLatch().captured_playhead_frame == 500);

    std::vector<float> drain1(64 * 2, 0.0f);
    int64_t clk1 = -1;
    REQUIRE(core.drainCaptureFrames(drain1.data(), 64, &clk1) == 64);
    CHECK(clk1 == 128);

    // Disarm and advance hardware clock by 256 frames (128 + 64 + 256 = 448).
    MutationCommand disarm{};
    disarm.type = MUT_SET_CAPTURE_STATE;
    disarm.flag_a = 0;
    pushSimpleMutation(core, disarm);

    std::vector<float> gap_out(256 * 2, 0.0f);
    REQUIRE(core.processBlock(nullptr, gap_out.data(), 256) == MUSE_OK);

    MutationCommand seek2{};
    seek2.type = MUT_SEEK_SAMPLE;
    seek2.sample_frame_a = 1200;
    pushSimpleMutation(core, seek2);

    pushSimpleMutation(core, arm);

    std::vector<float> mic2(64 * 2, -0.3f);
    REQUIRE(core.processBlock(mic2.data(), out.data(), 64) == MUSE_OK);
    CHECK(core.captureLatch().clock_latched.load());
    CHECK(core.captureLatch().captured_sample_clock == 448);
    CHECK(core.captureLatch().captured_playhead_frame == 1200);

    std::vector<float> drain2(64 * 2, 0.0f);
    int64_t clk2 = -1;
    REQUIRE(core.drainCaptureFrames(drain2.data(), 64, &clk2) == 64);
    CHECK(clk2 == 448);
    CHECK_THAT(drain2[0], Catch::Matchers::WithinAbs(-0.3f, 1e-6f));
  }
}

TEST_CASE(
    "Loop-pass tagged lookahead events wait for loop wrap instead of firing early",
    "[engine_cycle]") {
  AudioEngineCore core;
  REQUIRE(core.initializeWithConfig(defaultStereoConfig()) == MUSE_OK);
  const int32_t sf_id = loadTestSf2(core);
  assignPatch(core, 0, sf_id);

  MutationCommand loop{};
  loop.type = MUT_SET_LOOP_REGION;
  loop.flag_a = 1;
  loop.sample_frame_a = 100;
  loop.sample_frame_b = 500;
  pushSimpleMutation(core, loop);

  MutationCommand seek{};
  seek.type = MUT_SEEK_SAMPLE;
  seek.target_epoch = 1;
  seek.sample_frame_a = 300;
  pushSimpleMutation(core, seek);

  MutationCommand play{};
  play.type = MUT_SET_PLAYING;
  play.flag_a = 1;
  pushSimpleMutation(core, play);

  // Queue a trailing Pass-0 note-off right at loop_end_frame (500), followed
  // immediately by Pass-1's wrapped NoteOn at loop_start_frame (100).
  std::array<SynthNoteEvent, 2> events{};
  events[0].epoch = 1;
  events[0].target_sample_frame = 500;
  events[0].type = EVT_NOTE_OFF;
  events[0].channel = 0;
  events[0].key_or_cc = 60;
  events[0].velocity_or_val = 0;
  events[0].reserved = 0;

  events[1].epoch = 1;
  events[1].target_sample_frame = 100;
  events[1].type = EVT_NOTE_ON;
  events[1].channel = 0;
  events[1].key_or_cc = 60;
  events[1].velocity_or_val = 110;
  events[1].reserved = 1;

  uint32_t pushed = 0;
  REQUIRE(core.pushEvents(events.data(), 2, &pushed) == MUSE_OK);
  REQUIRE(pushed == 2);

  // Block 1 covers [300, 428) inside Pass 0: Pass-1 NoteOn MUST NOT fire early.
  std::vector<float> block_pre(128 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, block_pre.data(), 128) == MUSE_OK);
  CHECK(maxAbsRange(block_pre, 0, 128, 2) == 0.0f);
  CHECK(core.playheadAtomic() == 428);

  TelemetryFrame tf_pre{};
  REQUIRE(core.drainTelemetry(&tf_pre, 1) == 1);
  CHECK((tf_pre.reserved[0] | (tf_pre.reserved[1] << 8)) == 0);

  // Block 2 spans loop_end_frame (500): 72 frames on Pass 0 [428, 500) then
  // 184 frames on Pass 1 [100, 284). Pass 0 stays silent, Pass-0 note-off at 500
  // is discarded cleanly on wrap, and Pass-1 NoteOn at 100 triggers after wrap.
  std::vector<float> block_wrap(256 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, block_wrap.data(), 256) == MUSE_OK);
  CHECK(maxAbsRange(block_wrap, 0, 72, 2) == 0.0f);
  CHECK(maxAbsRange(block_wrap, 72, 256, 2) > 0.01f);
  CHECK(core.playheadAtomic() == 284);

  std::array<TelemetryFrame, 4> tf_post{};
  const uint32_t tf_count = core.drainTelemetry(tf_post.data(), 4);
  REQUIRE(tf_count >= 1);
  const TelemetryFrame& last_tf = tf_post[tf_count - 1];
  CHECK((last_tf.reserved[0] | (last_tf.reserved[1] << 8)) == 1);

  // MUT_FLUSH_AND_ADVANCE_EPOCH resets rt_.loop_pass back to 0.
  MutationCommand flush{};
  flush.type = MUT_FLUSH_AND_ADVANCE_EPOCH;
  flush.target_epoch = 2;
  pushSimpleMutation(core, flush);

  std::vector<float> block_flush(64 * 2, 0.0f);
  REQUIRE(core.processBlock(nullptr, block_flush.data(), 64) == MUSE_OK);
  TelemetryFrame tf_flush{};
  REQUIRE(core.drainTelemetry(&tf_flush, 1) == 1);
  CHECK((tf_flush.reserved[0] | (tf_flush.reserved[1] << 8)) == 0);
}
