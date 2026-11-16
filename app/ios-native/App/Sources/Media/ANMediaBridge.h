#ifndef AN_MEDIA_BRIDGE_H
#define AN_MEDIA_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ANMediaToken ANMediaToken;
typedef struct {
    int32_t width, height, primaries, transfer, dolby_profile, audio_channels, sample_rate;
    double duration, frame_rate, rotation;
} ANMediaInfo;
typedef int32_t (*ANMediaVideoCallback)(void *context, void *pixel_buffer, double seconds);
typedef int32_t (*ANMediaAudioCallback)(void *context, const float *samples, int32_t frames, double seconds);
ANMediaToken *ANMediaTokenCreate(void);
void ANMediaTokenCancel(ANMediaToken *);
int32_t ANMediaTokenIsCancelled(ANMediaToken *);
void ANMediaTokenDestroy(ANMediaToken *);
int32_t ANMediaProbe(const char *url, const char *headers, ANMediaToken *, ANMediaInfo *info);
/* Decodes into retained-for-callback NV12 CVPixelBuffer and interleaved stereo Float32/48kHz PCM.
   Apple AVAssetWriter owns H.264/AAC encoding; no FFmpeg encoder registration is required. */
int32_t ANMediaDecode(const char *url, const char *headers, double start, int32_t width, int32_t height,
                      ANMediaToken *, void *context, ANMediaVideoCallback video, ANMediaAudioCallback audio);
#ifdef __cplusplus
}
#endif
#endif
