#pragma once

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
#include <algorithm>
#include <cmath>
#include <cstddef>
#include <cstdint>
#endif

// ---------------------------------------------------------------------------
// Centralized Engine, Timing, DSP, and POD Constants (C11 / C++17 Shared)
// ---------------------------------------------------------------------------
// Every dimensional bound, queue capacity, timeout, and DSP parameter used by
// L1-L3 lives here so neither C ABI headers (ffigen) nor C++ DSP paths embed
// magic literals.

#ifdef __cplusplus

// Queue & Ring Capacities (all power-of-two for mask-based SpscRingBuffer)
inline constexpr size_t kMutationQueueCapacity = 256;
inline constexpr size_t kEventQueueCapacity = 4096;
inline constexpr size_t kAuditionQueueCapacity = 256;
inline constexpr size_t kCaptureRingCapacityFrames = 65536;
inline constexpr size_t kTakePlaybackRingCapacityFrames = 65536;
inline constexpr size_t kTelemetryQueueCapacity = 512;

// Signal Graph, FluidSynth Multi-Bus & MIDI Bounds
inline constexpr uint32_t kMidiChannelCount = 16;
inline constexpr uint32_t kMaxMidiChannel = kMidiChannelCount - 1;
inline constexpr int32_t kAllMidiChannels = -1;
inline constexpr uint32_t kMaxMidiKeyOrCc = 127;
inline constexpr uint32_t kMaxProgramNum = 127;
inline constexpr uint32_t kMaxBankNum = 16383;
inline constexpr int32_t kMinPitchBendSigned = -8192;
inline constexpr int32_t kMaxPitchBendSigned = 8191;
inline constexpr int32_t kPitchBendCenter = 8192;
inline constexpr int32_t kMaxPitchBendUnsigned = 16383;
inline constexpr uint32_t kMaxActiveTakeRegions = 16; // 1 overwrite take per part
inline constexpr uint32_t kMonoChannelCount = 1;
inline constexpr uint32_t kMaxCaptureChannels = 2;
inline constexpr uint32_t kStereoChannelCount = 2;
inline constexpr uint32_t kFluidAudioGroups = kMidiChannelCount;
inline constexpr uint32_t kFluidEffectsChannelsPerGroup = 2; // reverb + chorus
inline constexpr uint32_t kFluidEffectsGroups = kMidiChannelCount;
inline constexpr uint32_t kMaxRenderBlockFrames = 4096;

// DSP Mathematical Constants & Audio Mastering Bounds
// Base of common logarithm in L_dB = 20 * log10(A / A0).
inline constexpr float kDecibelBase = 10.0f;
// Amplitude-to-dB multiplier (20) so gain ratio derives as 10^(dB / 20).
inline constexpr float kAmplitudeDbFactor = 20.0f;
// Polyphonic multi-bus headroom before master limiter (-8 dB -> ~0.398x).
inline constexpr float kDefaultSynthHeadroomDb = -8.0f;
inline constexpr int32_t kDefaultSynthPolyphony = 256;
inline constexpr double kDefaultSynthSampleRate = 48000.0;
inline constexpr double kMinSynthSampleRate = 8000.0;
inline constexpr double kMaxSynthSampleRate = 96000.0;
// Soft limiter brickwall ceiling (~ -0.087 dBFS via 20 * log10(0.99)).
inline constexpr float kLimiterCeiling = 0.99f;
// Soft limiter knee threshold (~ -0.915 dBFS via 20 * log10(0.90)).
inline constexpr float kLimiterSoftKneeThreshold = 0.90f;
// 24-bit DAC theoretical floor (~ floor(20 * log10(2^24)) = 144 dB).
inline constexpr float kDac24BitDynamicRangeDb = 144.0f;
inline constexpr float kMinDbGainClamp = -kDac24BitDynamicRangeDb;
inline constexpr float kMaxDbGainClamp = 24.0f;
inline constexpr float kDefaultGainDb = 0.0f;
inline constexpr float kMinPan = -1.0f;
inline constexpr float kCenterPan = 0.0f;
inline constexpr float kMaxPan = 1.0f;
inline constexpr int32_t kFluidSynthSfFailed = -1;

// Scheduling, Lookahead, Web & Butler Thresholds
inline constexpr uint32_t kLookaheadWindowMs = 200;
inline constexpr uint32_t kMsPerSecond = 1000;
inline constexpr int64_t kImmediateDispatchFrame = -1;
inline constexpr uint32_t kBytesPerKib = 1024u;
inline constexpr uint32_t kBytesPerMib = kBytesPerKib * kBytesPerKib;
inline constexpr uint32_t kMaxWebSoundFontMib = 64u;
inline constexpr uint32_t kMaxWebSoundFontBytes = kMaxWebSoundFontMib * kBytesPerMib;
inline constexpr uint32_t kWebCaptureBatchQuanta = 32;
inline constexpr uint32_t kMaxSoundFontPresets = 2048;
inline constexpr size_t kButlerWakeWatermarkFrames = 2048;
inline constexpr int64_t kTakePrefetchFrames = 16384;
inline constexpr size_t kTakeWorkerChunkFrames = 512;
inline constexpr size_t kCaptureDrainChunkFrames = 2048;
inline constexpr uint32_t kButlerPollIntervalMs = 2;
inline constexpr uint32_t kButlerIdlePollIntervalMs = 20;
inline constexpr uint32_t kSynthSuspendTimeoutMs = 2000;
inline constexpr uint32_t kButlerDrainTimeoutMs = 5000;

// POD String / Path Capacities, CSR & Alignment
inline constexpr size_t kCacheLineBytes = 64;
inline constexpr size_t kDeviceFingerprintBufferSize = 128;
inline constexpr size_t kPresetNameBufferSize = 64;
inline constexpr size_t kStagingPathBufferSize = 512;
inline constexpr size_t kSha256DigestBytes = 32;
inline constexpr size_t kHexCharsPerByte = 2;
inline constexpr size_t kSha256HexLength = kSha256DigestBytes * kHexCharsPerByte;
inline constexpr size_t kSha256HexBufferSize = kSha256HexLength + 1;
inline constexpr size_t kTakeIdBufferSize = 128;
inline constexpr size_t kCasPathBufferSize = 512;
inline constexpr size_t kSha256FileChunkBytes = 65536;
inline constexpr size_t kTelemetryReservedBytes = 3;
inline constexpr size_t kFinalizedReceiptTrailingPadBytes = 7;
// ARMv8 FPCR.FZ bit position; bitmask is derived via uint64_t{1} << bit.
inline constexpr unsigned kAarch64FpcrFlushToZeroBit = 24u;

// Platform Audio HAL & Web Render Quantum Constants
inline constexpr const char* kHeadlessAudioEnvVar = "MUSE_HEADLESS_AUDIO";
inline constexpr const char* kHeadlessAudioEnabledValue = "1";
inline constexpr const char* kHeadlessDeviceFingerprint =
    "headless-miniaudio-null";
inline constexpr const char* kUnknownDeviceFingerprint =
    "miniaudio-unknown-device";
inline constexpr uint32_t kWebRenderQuantumFrames = 128;
inline constexpr size_t kDefaultLogBufferSize = 256;

#else // C11 definitions for ffigen compatibility

#define kImmediateDispatchFrame ((int64_t)-1)
#define kDefaultSynthSampleRate 48000.0
#define kMinSynthSampleRate 8000.0
#define kMaxSynthSampleRate 96000.0
#define kLimiterCeiling 0.99f
#define kLimiterSoftKneeThreshold 0.90f
#define kDecibelBase 10.0f
#define kAmplitudeDbFactor 20.0f
#define kDefaultSynthHeadroomDb (-8.0f)
#define kDac24BitDynamicRangeDb 144.0f
#define kMinDbGainClamp (-kDac24BitDynamicRangeDb)
#define kMaxDbGainClamp 24.0f
#define kDefaultGainDb 0.0f
#define kMinPan (-1.0f)
#define kCenterPan 0.0f
#define kMaxPan 1.0f
#define kHeadlessAudioEnvVar "MUSE_HEADLESS_AUDIO"
#define kHeadlessAudioEnabledValue "1"
#define kHeadlessDeviceFingerprint "headless-miniaudio-null"
#define kUnknownDeviceFingerprint "miniaudio-unknown-device"

enum {
  kMutationQueueCapacity = 256,
  kEventQueueCapacity = 4096,
  kAuditionQueueCapacity = 256,
  kCaptureRingCapacityFrames = 65536,
  kTakePlaybackRingCapacityFrames = 65536,
  kTelemetryQueueCapacity = 512,
  kMidiChannelCount = 16,
  kMaxMidiChannel = kMidiChannelCount - 1,
  kAllMidiChannels = -1,
  kMaxMidiKeyOrCc = 127,
  kMaxProgramNum = 127,
  kMaxBankNum = 16383,
  kMinPitchBendSigned = -8192,
  kMaxPitchBendSigned = 8191,
  kPitchBendCenter = 8192,
  kMaxPitchBendUnsigned = 16383,
  kMaxActiveTakeRegions = 16,
  kMonoChannelCount = 1,
  kMaxCaptureChannels = 2,
  kStereoChannelCount = 2,
  kFluidAudioGroups = kMidiChannelCount,
  kFluidEffectsChannelsPerGroup = 2,
  kFluidEffectsGroups = kMidiChannelCount,
  kMaxRenderBlockFrames = 4096,
  kDefaultSynthPolyphony = 256,
  kFluidSynthSfFailed = -1,
  kLookaheadWindowMs = 200,
  kMsPerSecond = 1000,
  kBytesPerKib = 1024,
  kBytesPerMib = kBytesPerKib * kBytesPerKib,
  kMaxWebSoundFontMib = 64,
  kMaxWebSoundFontBytes = kMaxWebSoundFontMib * kBytesPerMib,
  kWebCaptureBatchQuanta = 32,
  kMaxSoundFontPresets = 2048,
  kButlerWakeWatermarkFrames = 2048,
  kTakePrefetchFrames = 16384,
  kTakeWorkerChunkFrames = 512,
  kCaptureDrainChunkFrames = 2048,
  kButlerPollIntervalMs = 2,
  kButlerIdlePollIntervalMs = 20,
  kSynthSuspendTimeoutMs = 2000,
  kButlerDrainTimeoutMs = 5000,
  kCacheLineBytes = 64,
  kDeviceFingerprintBufferSize = 128,
  kPresetNameBufferSize = 64,
  kStagingPathBufferSize = 512,
  kSha256DigestBytes = 32,
  kHexCharsPerByte = 2,
  kSha256HexLength = kSha256DigestBytes * kHexCharsPerByte,
  kSha256HexBufferSize = kSha256HexLength + 1,
  kTakeIdBufferSize = 128,
  kCasPathBufferSize = 512,
  kSha256FileChunkBytes = 65536,
  kTelemetryReservedBytes = 3,
  kFinalizedReceiptTrailingPadBytes = 7,
  kAarch64FpcrFlushToZeroBit = 24,
  kWebRenderQuantumFrames = 128,
  kDefaultLogBufferSize = 256
};

#endif // __cplusplus

// ---------------------------------------------------------------------------
// Shared Inline C++ DSP Mathematical Helpers
// ---------------------------------------------------------------------------
#ifdef __cplusplus
namespace muse::engine::dsp {

struct StereoPanGains {
  float left;
  float right;
};

/// Converts gain in decibels clamped to [kMinDbGainClamp, kMaxDbGainClamp]
/// into linear amplitude via 10^(dB / 20). Non-finite inputs fail safe to 0.
inline float dbToLinear(float gain_db) noexcept {
  if (!std::isfinite(gain_db)) {
    return 0.0f;
  }
  const float clamped_db = std::clamp(gain_db, kMinDbGainClamp, kMaxDbGainClamp);
  return std::pow(kDecibelBase, clamped_db / kAmplitudeDbFactor);
}

/// Computes constant-power stereo pan coefficients (L = cos(theta), R = sin(theta))
/// over theta in [0, pi/2] derived from pan in [kMinPan, kMaxPan].
/// Clamps negative rounding residue at pi/2 to 0.0f for strict non-negativity.
inline StereoPanGains computeConstantPowerPan(float pan) noexcept {
  const float safe_pan = std::isfinite(pan) ? pan : kCenterPan;
  const float clamped = std::clamp(safe_pan, kMinPan, kMaxPan);
  const float normalized = (clamped - kMinPan) / (kMaxPan - kMinPan);
  const float half_pi = std::acos(0.0f);
  const float angle = normalized * half_pi;
  return StereoPanGains{
      std::max(0.0f, std::cos(angle)),
      std::max(0.0f, std::sin(angle)),
  };
}

/// Folds a stereo sample pair down to mono with unity sum energy scaling.
inline float foldStereoToMono(float left, float right) noexcept {
  return (left + right) / static_cast<float>(kStereoChannelCount);
}

/// C1-continuous, strictly monotonic soft-knee brickwall limiter bounded by
/// |output| <= kLimiterCeiling. Non-finite inputs sanitize to 0.0f.
inline float applySoftLimiter(float sample) noexcept {
  if (!std::isfinite(sample)) {
    return 0.0f;
  }
  const float abs_x = std::fabs(sample);
  if (abs_x <= kLimiterSoftKneeThreshold) {
    return sample;
  }
  const float headroom = kLimiterCeiling - kLimiterSoftKneeThreshold;
  const float excess = abs_x - kLimiterSoftKneeThreshold;
  const float limited_mag =
      kLimiterSoftKneeThreshold + headroom * (excess / (headroom + excess));
  return std::copysign(std::min(limited_mag, kLimiterCeiling), sample);
}

} // namespace muse::engine::dsp
#endif // __cplusplus
