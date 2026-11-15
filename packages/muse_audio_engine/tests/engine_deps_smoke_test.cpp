#include <catch2/catch_test_macros.hpp>

#include <fluidsynth.h>
#include <miniaudio.h>
#include <picosha2.h>

#include <array>
#include <cstdint>
#include <string>
#include <vector>

TEST_CASE("FluidSynth initializes in 32-bit float mode and renders silence", "[deps][fluidsynth]") {
  fluid_settings_t* settings = new_fluid_settings();
  REQUIRE(settings != nullptr);

  REQUIRE(fluid_settings_setnum(settings, "synth.sample-rate", 48000.0) == FLUID_OK);
  REQUIRE(fluid_settings_setint(settings, "synth.threadsafe-api", 0) == FLUID_OK);

  fluid_synth_t* synth = new_fluid_synth(settings);
  REQUIRE(synth != nullptr);

  constexpr int kFrames = 128;
  std::vector<float> left(kFrames, 1.0f);
  std::vector<float> right(kFrames, 1.0f);

  const int rc = fluid_synth_write_float(synth, kFrames, left.data(), 0, 1, right.data(), 0, 1);
  REQUIRE(rc == FLUID_OK);
  for (int i = 0; i < kFrames; ++i) {
    REQUIRE(left[i] == 0.0f);
    REQUIRE(right[i] == 0.0f);
  }

  delete_fluid_synth(synth);
  delete_fluid_settings(settings);
}

TEST_CASE("miniaudio data converter and WAV encoder config types are usable", "[deps][miniaudio]") {
  ma_data_converter_config converter_cfg = ma_data_converter_config_init(
      ma_format_f32,
      ma_format_f32,
      1,
      2,
      44100,
      48000);
  ma_data_converter converter = {};
  REQUIRE(ma_data_converter_init(&converter_cfg, nullptr, &converter) == MA_SUCCESS);

  std::array<float, 64> mono_in{};
  std::array<float, 256> stereo_out{};
  ma_uint64 in_frames = mono_in.size();
  ma_uint64 out_frames = stereo_out.size() / 2;
  REQUIRE(ma_data_converter_process_pcm_frames(
              &converter, mono_in.data(), &in_frames, stereo_out.data(), &out_frames) == MA_SUCCESS);
  ma_data_converter_uninit(&converter, nullptr);

  ma_encoder_config enc_cfg = ma_encoder_config_init(ma_encoding_format_wav, ma_format_f32, 2, 48000);
  REQUIRE(enc_cfg.encodingFormat == ma_encoding_format_wav);
  REQUIRE(enc_cfg.format == ma_format_f32);
  REQUIRE(enc_cfg.channels == 2);
  REQUIRE(enc_cfg.sampleRate == 48000);
}

TEST_CASE("PicoSHA2 computes standard lowercase SHA-256 hex digests", "[deps][picosha2]") {
  const std::string input = "abc";
  const std::string hex = picosha2::hash256_hex_string(input);
  REQUIRE(hex == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad");
}
