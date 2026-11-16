#ifndef ANI_TORRENT_BRIDGE_H
#define ANI_TORRENT_BRIDGE_H
#include <stdint.h>
#include <stddef.h>
#ifdef __cplusplus
extern "C" {
#endif
typedef struct ANITEngine ANITEngine;
typedef struct ANITTorrent ANITTorrent;
typedef struct ANITReadToken ANITReadToken;
typedef struct {
    int64_t wanted;
    int64_t completed;
    int64_t download_rate;
    int64_t upload_rate;
    int32_t peers;
    int32_t paused;
    int32_t metadata_ready;
    int32_t failed;
} ANITStatus;
ANITEngine *ANITCreateEngine(char *error, size_t capacity);
void ANITDestroyEngine(ANITEngine *engine);
int32_t ANITListenPort(ANITEngine *engine);
ANITTorrent *ANITAddMagnet(ANITEngine *, const char *uri, const char *directory, char *error, size_t capacity);
ANITTorrent *ANITAddTorrent(ANITEngine *, const uint8_t *data, size_t size, const char *directory, char *error, size_t capacity);
void ANITCloseTorrent(ANITTorrent *torrent);
int32_t ANITFileCount(ANITTorrent *torrent);
int32_t ANITFileInfo(ANITTorrent *, int32_t index, char *path, size_t capacity, int64_t *size);
int32_t ANITSelectFile(ANITTorrent *, int32_t index);
ANITStatus ANITGetStatus(ANITTorrent *torrent);
void ANITSetPaused(ANITTorrent *, int32_t paused);
void ANITSaveResume(ANITTorrent *torrent);
void ANITRemove(ANITTorrent *torrent, int32_t delete_files);
ANITReadToken *ANITCreateReadToken(void);
void ANITCancelRead(ANITReadToken *token);
void ANITDestroyReadToken(ANITReadToken *token);
/* Returns bytes copied, 0 at EOF, -1 on failure, -2 on cancellation, -3 on timeout. */
int32_t ANITRead(ANITTorrent *, int32_t index, int64_t offset, uint8_t *destination, int32_t capacity,
                 int32_t timeout_milliseconds, ANITReadToken *token);
#ifdef __cplusplus
}
#endif
#endif
