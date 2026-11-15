#pragma once

#include <stddef.h>
#include <stdint.h>

#include "../engine_constants.h"
#include "../hal_contract.h"

#ifdef __cplusplus
#include <type_traits>
extern "C" {
#endif

typedef uint8_t MutationType;
enum {
  MUT_SET_PLAYING = 1,
  MUT_SEEK_SAMPLE = 2,
  MUT_SET_LOOP_REGION = 3,
  MUT_FLUSH_AND_ADVANCE_EPOCH = 4,
  MUT_ASSIGN_CHANNEL_PATCH = 5,     // channel, int_param_a (sf_handle), int_param_b (bank), int_param_c (program)
  MUT_SET_CHANNEL_MIX = 6,          // channel, float_param_a (gain_db), float_param_b (pan)
  MUT_ALL_NOTES_OFF_CHANNEL = 7,
  MUT_SET_MONITOR_GAIN = 8,
  MUT_SET_CAPTURE_STATE = 9,
  MUT_SET_SYNTH_SUSPENDED = 10,     // flag_a: 1 = suspend FluidSynth rendering for SF2 load/unload, 0 = resume
  MUT_SET_SCHEDULED_WATERMARK = 11  // target_epoch + sample_frame_a: lookahead scheduled-up-to frame
};

typedef struct MutationCommand {
  MutationType type;
  uint8_t channel;          // 0..15
  uint8_t flag_a;           // bool: is_playing / loop_enabled / capture_active / synth_suspended
  uint8_t reserved;
  int32_t int_param_a;      // sfont_handle
  int32_t int_param_b;      // bank_num (0..16383)
  int32_t int_param_c;      // program_num (0..127)
  float float_param_a;      // gain_db / monitor_gain
  float float_param_b;      // pan (-1.0f .. 1.0f)
  uint64_t target_epoch;    // MUT_FLUSH_AND_ADVANCE_EPOCH / MUT_SEEK_SAMPLE / MUT_SET_SCHEDULED_WATERMARK
  int64_t sample_frame_a;   // seek frame / loop_start_frame / scheduled watermark frame
  int64_t sample_frame_b;   // loop_end_frame
} MutationCommand;

typedef uint8_t SynthEventType;
enum {
  EVT_NOTE_ON = 1,
  EVT_NOTE_OFF = 2,
  EVT_CONTROL_CHANGE = 3,
  EVT_PITCH_BEND = 4
};

typedef struct SynthNoteEvent {
  uint64_t epoch;
  int64_t target_sample_frame;
  SynthEventType type;
  uint8_t channel;          // 0..15
  uint8_t key_or_cc;        // 0..127
  uint8_t velocity_or_val;  // 0..127
  int16_t pitch_bend;       // -8192..8191
  uint16_t reserved;
} SynthNoteEvent;

// Pre-mixed stereo f32 frame pushed by Butler / Web OPFS Worker into TakePlaybackRingBuffer
typedef struct TakePlaybackStereoFrame {
  uint64_t epoch;
  int64_t target_sample_frame;
  float left;
  float right;
} TakePlaybackStereoFrame;

typedef struct TelemetryFrame {
  int64_t playhead_sample_frame;
  uint64_t active_epoch;
  float output_peak_l;
  float output_peak_r;
  float output_rms_l;
  float output_rms_r;
  float input_peak;
  float input_rms;
  uint8_t is_playing;
  uint8_t is_capturing;
  uint8_t event_queue_underrun;
  uint8_t capture_buffer_overflow;
  uint8_t take_playback_underrun;
  uint8_t reserved[kTelemetryReservedBytes];
} TelemetryFrame;

typedef struct FinalizedCaptureReceipt {
  MuseStatus status;               // int32_t
  int32_t reserved_pad0;           // Explicit 8-byte alignment padding before int64_t
  int64_t captured_sample_clock;   // Hardware sampleClock at first captured frame
  int64_t captured_playhead_frame; // Timeline playhead frame at first captured frame
  int64_t duration_frames;
  uint32_t sample_rate;
  uint16_t channel_count;
  uint16_t reserved;
  uint32_t output_buffer_frames;   // Latched at capture start
  uint32_t input_buffer_frames;    // Latched at capture start
  char staging_path[kStagingPathBufferSize];
  char sha256_hex[kSha256HexBufferSize];
  char reserved_pad1[kFinalizedReceiptTrailingPadBytes];
} FinalizedCaptureReceipt;

#ifdef __cplusplus
} // extern "C"

static_assert(std::is_trivially_copyable_v<MutationCommand>);
static_assert(sizeof(MutationCommand) == 48);
static_assert(std::is_trivially_copyable_v<SynthNoteEvent>);
static_assert(sizeof(SynthNoteEvent) == 24);
static_assert(std::is_trivially_copyable_v<TakePlaybackStereoFrame>);
static_assert(sizeof(TakePlaybackStereoFrame) == 24);
static_assert(std::is_trivially_copyable_v<TelemetryFrame>);
static_assert(sizeof(TelemetryFrame) == 48);
static_assert(std::is_trivially_copyable_v<FinalizedCaptureReceipt>);
static_assert(sizeof(FinalizedCaptureReceipt) == 632);
#endif
