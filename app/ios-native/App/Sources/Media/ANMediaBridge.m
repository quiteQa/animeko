#import "ANMediaBridge.h"
#import <Foundation/Foundation.h>
@import Libavformat;
@import Libavcodec;
@import Libavutil;
@import Libswscale;
@import Libswresample;
#import <CoreVideo/CoreVideo.h>
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

struct ANMediaToken { atomic_int cancelled; atomic_int_fast64_t deadline; };
ANMediaToken *ANMediaTokenCreate(void) {
    ANMediaToken *token = calloc(1, sizeof(*token));
    if (token) { atomic_init(&token->cancelled, 0); atomic_init(&token->deadline, 0); }
    return token;
}
void ANMediaTokenCancel(ANMediaToken *token) { if (token) atomic_store(&token->cancelled, 1); }
int32_t ANMediaTokenIsCancelled(ANMediaToken *token) { return !token || atomic_load(&token->cancelled); }
void ANMediaTokenDestroy(ANMediaToken *token) { free(token); }
static int interrupted(void *pointer) {
    ANMediaToken *token = pointer;
    int64_t deadline = token ? atomic_load(&token->deadline) : 0;
    return ANMediaTokenIsCancelled(token) || (deadline && av_gettime_relative() > deadline);
}
static int open_input(const char *url, const char *headers, ANMediaToken *token, AVFormatContext **format) {
    if (!token || !url) return AVERROR(EINVAL);
    // Libav error codes are returned to the caller; raw library logs can contain authenticated URLs.
    av_log_set_level(AV_LOG_QUIET);
    *format = avformat_alloc_context();
    if (!*format) return AVERROR(ENOMEM);
    (*format)->interrupt_callback = (AVIOInterruptCB){interrupted, token};
    atomic_store(&token->deadline, av_gettime_relative() + 8000000);
    AVDictionary *options = NULL;
    if (headers && *headers) av_dict_set(&options, "headers", headers, 0);
    av_dict_set(&options, "rw_timeout", "8000000", 0);
    av_dict_set(&options, "probesize", "8388608", 0);
    av_dict_set(&options, "analyzeduration", "5000000", 0);
    int result = avformat_open_input(format, url, NULL, &options);
    av_dict_free(&options);
    if (result >= 0) result = avformat_find_stream_info(*format, NULL);
    return result;
}
int32_t ANMediaProbe(const char *url, const char *headers, ANMediaToken *token, ANMediaInfo *info) {
    if (!info) return AVERROR(EINVAL);
    memset(info, 0, sizeof(*info));
    AVFormatContext *format = NULL;
    int result = open_input(url, headers, token, &format);
    if (result < 0) goto done;
    int index = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    if (index < 0) { result = index; goto done; }
    AVStream *stream = format->streams[index];
    AVCodecParameters *parameters = stream->codecpar;
    AVRational aspect = av_guess_sample_aspect_ratio(format, stream, NULL);
    info->aspect_num = aspect.num > 0 ? aspect.num : 1; info->aspect_den = aspect.den > 0 ? aspect.den : 1;
    info->width = parameters->width; info->height = parameters->height;
    info->primaries = parameters->color_primaries; info->transfer = parameters->color_trc;
    info->duration = format->duration > 0 ? (double)format->duration / AV_TIME_BASE : 0;
    AVRational rate = av_guess_frame_rate(format, stream, NULL);
    info->frame_rate = rate.den && rate.num ? av_q2d(rate) : 24;
    const AVPacketSideData *side = av_packet_side_data_get(parameters->coded_side_data,
        parameters->nb_coded_side_data, AV_PKT_DATA_DOVI_CONF);
    if (side && side->size >= sizeof(AVDOVIDecoderConfigurationRecord))
        info->dolby_profile = ((AVDOVIDecoderConfigurationRecord *)side->data)->dv_profile;
    side = av_packet_side_data_get(parameters->coded_side_data, parameters->nb_coded_side_data, AV_PKT_DATA_DISPLAYMATRIX);
    if (side && side->size >= 9 * sizeof(int32_t)) info->rotation = av_display_rotation_get((int32_t *)side->data);
    index = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    if (index >= 0) {
        info->audio_channels = format->streams[index]->codecpar->ch_layout.nb_channels;
        info->sample_rate = format->streams[index]->codecpar->sample_rate;
    }
done:
    avformat_close_input(&format);
    return result < 0 ? result : 0;
}

static enum AVPixelFormat choose_video_format(AVCodecContext *codec, const enum AVPixelFormat *formats) {
    for (const enum AVPixelFormat *format = formats; *format != AV_PIX_FMT_NONE; ++format)
        if (*format == AV_PIX_FMT_VIDEOTOOLBOX) return *format;
    return formats[0];
}
static AVCodecContext *open_decoder(AVFormatContext *format, int index, int hardware) {
    if (index < 0) return NULL;
    AVCodecParameters *parameters = format->streams[index]->codecpar;
    const AVCodec *codec = avcodec_find_decoder(parameters->codec_id);
    if (!codec) return NULL;
    AVCodecContext *decoder = avcodec_alloc_context3(codec);
    if (!decoder) return NULL;
    if (avcodec_parameters_to_context(decoder, parameters) < 0) goto fail;
    decoder->thread_count = 2;
    if (hardware) {
        for (int i = 0;; ++i) {
            const AVCodecHWConfig *config = avcodec_get_hw_config(codec, i);
            if (!config) break;
            if (config->device_type == AV_HWDEVICE_TYPE_VIDEOTOOLBOX &&
                (config->methods & AV_CODEC_HW_CONFIG_METHOD_HW_DEVICE_CTX)) {
                if (av_hwdevice_ctx_create(&decoder->hw_device_ctx, AV_HWDEVICE_TYPE_VIDEOTOOLBOX, NULL, NULL, 0) >= 0)
                    decoder->get_format = choose_video_format;
                break;
            }
        }
    }
    if (avcodec_open2(decoder, codec, NULL) >= 0) return decoder;
fail:
    avcodec_free_context(&decoder);
    return NULL;
}

typedef struct {
    struct SwsContext *scale;
    SwrContext *resample;
    CVPixelBufferPoolRef pool;
    int width, height;
    double start, origin, audio_next, video_next;
    void *context;
    ANMediaVideoCallback video;
    ANMediaAudioCallback audio;
    ANMediaToken *token;
} DecodeOutput;

static int emit_video(DecodeOutput *output, AVFrame *frame, AVStream *stream) {
    if (ANMediaTokenIsCancelled(output->token)) return AVERROR_EXIT;
    if (frame->color_trc == AVCOL_TRC_SMPTE2084 || frame->color_trc == AVCOL_TRC_ARIB_STD_B67 ||
        av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_RPU_BUFFER) || av_frame_get_side_data(frame, AV_FRAME_DATA_DOVI_METADATA)) return AVERROR(ENOTSUP);
    double pts = frame->best_effort_timestamp == AV_NOPTS_VALUE ? output->video_next
        : frame->best_effort_timestamp * av_q2d(stream->time_base) - output->origin - output->start;
    AVRational rate = stream->avg_frame_rate;
    output->video_next = pts + (rate.num > 0 && rate.den > 0 ? av_q2d(av_inv_q(rate)) : 1.0 / 24);
    if (pts < -0.001) return 0;
    AVFrame *software = NULL;
    if (frame->format == AV_PIX_FMT_VIDEOTOOLBOX) {
        software = av_frame_alloc();
        if (!software) return AVERROR(ENOMEM);
        int result = av_hwframe_transfer_data(software, frame, 0);
        if (result < 0) { av_frame_free(&software); return result; }
        av_frame_copy_props(software, frame);
        frame = software;
    }
    output->scale = sws_getCachedContext(output->scale, frame->width, frame->height, frame->format,
        output->width, output->height, AV_PIX_FMT_NV12, SWS_BILINEAR, NULL, NULL, NULL);
    if (!output->scale) { av_frame_free(&software); return AVERROR(ENOMEM); }
    const int *source = sws_getCoefficients(frame->colorspace == AVCOL_SPC_UNSPECIFIED
        ? (frame->width > 720 ? SWS_CS_ITU709 : SWS_CS_ITU601) : frame->colorspace);
    const int *destination = sws_getCoefficients(SWS_CS_ITU709);
    sws_setColorspaceDetails(output->scale, source, frame->color_range == AVCOL_RANGE_JPEG,
        destination, 0, 0, 1 << 16, 1 << 16);
    CVPixelBufferRef buffer = NULL;
    CVReturn status = CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, output->pool, &buffer);
    if (status != kCVReturnSuccess) { av_frame_free(&software); return AVERROR(ENOMEM); }
    CVPixelBufferLockBaseAddress(buffer, 0);
    uint8_t *planes[4] = {CVPixelBufferGetBaseAddressOfPlane(buffer, 0), CVPixelBufferGetBaseAddressOfPlane(buffer, 1), NULL, NULL};
    int strides[4] = {(int)CVPixelBufferGetBytesPerRowOfPlane(buffer, 0), (int)CVPixelBufferGetBytesPerRowOfPlane(buffer, 1), 0, 0};
    int rows = sws_scale(output->scale, (const uint8_t *const *)frame->data, frame->linesize, 0, frame->height, planes, strides);
    CVPixelBufferUnlockBaseAddress(buffer, 0);
    av_frame_free(&software);
    if (rows <= 0) { CVPixelBufferRelease(buffer); return AVERROR_EXTERNAL; }
    CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, kCVImageBufferColorPrimaries_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_709_2, kCVAttachmentMode_ShouldPropagate);
    int accepted = output->video(output->context, buffer, fmax(0, pts));
    CVPixelBufferRelease(buffer);
    return accepted ? 0 : AVERROR_EXIT;
}
static int emit_audio(DecodeOutput *output, AVFrame *frame, AVStream *stream, AVCodecContext *decoder) {
    if (!output->audio) return 0;
    if (ANMediaTokenIsCancelled(output->token)) return AVERROR_EXIT;
    int rate = frame->sample_rate ? frame->sample_rate : decoder->sample_rate;
    if (!output->resample) {
        AVChannelLayout stereo = AV_CHANNEL_LAYOUT_STEREO;
        int result = swr_alloc_set_opts2(&output->resample, &stereo, AV_SAMPLE_FMT_FLT, 48000,
            &frame->ch_layout, frame->format, rate, 0, NULL);
        if (result < 0 || swr_init(output->resample) < 0) return AVERROR_EXTERNAL;
    }
    int64_t delay = swr_get_delay(output->resample, rate);
    int capacity = (int)av_rescale_rnd(delay + frame->nb_samples, 48000, rate, AV_ROUND_UP);
    uint8_t *samples = NULL; int line_size = 0;
    if (av_samples_alloc(&samples, &line_size, 2, capacity, AV_SAMPLE_FMT_FLT, 0) < 0) return AVERROR(ENOMEM);
    int count = swr_convert(output->resample, &samples, capacity, (const uint8_t **)frame->extended_data, frame->nb_samples);
    if (count < 0) { av_freep(&samples); return count; }
    double pts = frame->best_effort_timestamp == AV_NOPTS_VALUE ? output->audio_next
        : frame->best_effort_timestamp * av_q2d(stream->time_base) - output->origin - output->start - (double)delay / rate;
    int skip = pts < 0 ? (int)fmin(count, ceil(-pts * 48000)) : 0;
    pts += (double)skip / 48000;
    int accepted = count <= skip || output->audio(output->context, (const float *)samples + skip * 2, count - skip, fmax(0, pts));
    output->audio_next = fmax(0, pts) + (double)(count - skip) / 48000;
    av_freep(&samples);
    return accepted ? 0 : AVERROR_EXIT;
}
static int drain(DecodeOutput *output, AVCodecContext *decoder, AVStream *stream, int video) {
    AVFrame *frame = av_frame_alloc();
    if (!frame) return AVERROR(ENOMEM);
    int result;
    while ((result = avcodec_receive_frame(decoder, frame)) >= 0) {
        result = video ? emit_video(output, frame, stream) : emit_audio(output, frame, stream, decoder);
        av_frame_unref(frame);
        if (result < 0) break;
    }
    av_frame_free(&frame);
    return result == AVERROR(EAGAIN) || result == AVERROR_EOF ? 0 : result;
}
int32_t ANMediaDecode(const char *url, const char *headers, double start, int32_t width, int32_t height,
                      ANMediaToken *token, void *context, ANMediaVideoCallback video, ANMediaAudioCallback audio) {
    if (!video || width <= 0 || height <= 0 || width > 4096 || height > 4096) return AVERROR(EINVAL);
    AVFormatContext *format = NULL; AVCodecContext *vd = NULL, *ad = NULL; AVPacket *packet = NULL;
    NSDictionary *attributes = nil;
    DecodeOutput output = {0}; output.width = width; output.height = height;
    output.start = fmax(0, start); output.context = context; output.video = video; output.audio = audio; output.token = token;
    int result = open_input(url, headers, token, &format);
    if (result < 0) goto done;
    output.origin = format->start_time == AV_NOPTS_VALUE ? 0 : (double)format->start_time / AV_TIME_BASE;
    int vi = av_find_best_stream(format, AVMEDIA_TYPE_VIDEO, -1, -1, NULL, 0);
    int ai = av_find_best_stream(format, AVMEDIA_TYPE_AUDIO, -1, -1, NULL, 0);
    vd = open_decoder(format, vi, 1); ad = open_decoder(format, ai, 0);
    if (!vd || (ai >= 0 && !ad)) { result = AVERROR_DECODER_NOT_FOUND; goto done; }
    attributes = @{
        (id)kCVPixelBufferWidthKey: @(width), (id)kCVPixelBufferHeightKey: @(height),
        (id)kCVPixelBufferPixelFormatTypeKey: @(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
        (id)kCVPixelBufferIOSurfacePropertiesKey: @{},
    };
    if (CVPixelBufferPoolCreate(kCFAllocatorDefault, NULL, (__bridge CFDictionaryRef)attributes, &output.pool) != kCVReturnSuccess) {
        result = AVERROR(ENOMEM); goto done;
    }
    if (start > 0) {
        int64_t target = (int64_t)((start + output.origin) * AV_TIME_BASE);
        result = avformat_seek_file(format, -1, INT64_MIN, target, INT64_MAX, AVSEEK_FLAG_BACKWARD);
        if (result < 0) goto done;
    }
    packet = av_packet_alloc();
    if (!packet) { result = AVERROR(ENOMEM); goto done; }
    while (!ANMediaTokenIsCancelled(token)) {
        atomic_store(&token->deadline, av_gettime_relative() + 30000000);
        result = av_read_frame(format, packet);
        if (result < 0) break;
        AVCodecContext *decoder = packet->stream_index == vi ? vd : packet->stream_index == ai ? ad : NULL;
        if (decoder) {
            result = avcodec_send_packet(decoder, packet);
            if (result == AVERROR(EAGAIN)) {
                result = drain(&output, decoder, format->streams[packet->stream_index], decoder == vd);
                if (result >= 0) result = avcodec_send_packet(decoder, packet);
            }
            if (result >= 0) result = drain(&output, decoder, format->streams[packet->stream_index], decoder == vd);
        }
        av_packet_unref(packet);
        if (result < 0) break;
    }
    if (result == AVERROR_EOF && !ANMediaTokenIsCancelled(token)) {
        avcodec_send_packet(vd, NULL); result = drain(&output, vd, format->streams[vi], 1);
        if (result >= 0 && ad) { avcodec_send_packet(ad, NULL); result = drain(&output, ad, format->streams[ai], 0); }
    }
    if (ANMediaTokenIsCancelled(token)) result = AVERROR_EXIT;
done:
    av_packet_free(&packet); avcodec_free_context(&vd); avcodec_free_context(&ad); avformat_close_input(&format);
    sws_freeContext(output.scale); swr_free(&output.resample);
    if (output.pool) CVPixelBufferPoolRelease(output.pool);
    return result < 0 ? result : 0;
}
