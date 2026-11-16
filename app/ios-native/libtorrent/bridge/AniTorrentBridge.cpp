#include "AniTorrentBridge.h"
#include <libtorrent/add_torrent_params.hpp>
#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/read_resume_data.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_info.hpp>
#include <libtorrent/write_resume_data.hpp>
#include <algorithm>
#include <atomic>
#include <chrono>
#include <condition_variable>
#include <cstdio>
#include <filesystem>
#include <fstream>
#include <map>
#include <memory>
#include <mutex>
#include <set>
#include <thread>
#include <vector>

namespace lt = libtorrent;
namespace {
struct Torrent;
struct Engine {
    lt::session session;
    std::mutex mutex;
    std::vector<std::shared_ptr<Torrent>> torrents;
    std::atomic<bool> stopping{false};
    std::thread alerts;
    Engine();
    ~Engine();
    void poll();
};
struct Torrent {
    std::weak_ptr<Engine> engine;
    lt::torrent_handle handle;
    std::string directory;
    std::mutex mutex;
    std::condition_variable condition;
    std::map<int, std::vector<char>> pieces;
    std::set<int> requested;
    size_t cachedBytes = 0;
    std::atomic<bool> removed{false};
    std::atomic<bool> configured{false};
    std::atomic<bool> cacheEnabled{false};
};
lt::settings_pack settings() {
    lt::settings_pack pack;
    pack.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:0,[::]:0");
    pack.set_bool(lt::settings_pack::enable_dht, true);
    pack.set_bool(lt::settings_pack::enable_lsd, false);
    pack.set_bool(lt::settings_pack::enable_upnp, false);
    pack.set_bool(lt::settings_pack::enable_natpmp, false);
    pack.set_int(lt::settings_pack::connections_limit, 80);
    pack.set_int(lt::settings_pack::alert_mask, lt::alert_category::status | lt::alert_category::error | lt::alert_category::storage);
    return pack;
}
Engine::Engine() : session(settings()), alerts([this] { poll(); }) {}
Engine::~Engine() { stopping = true; if (alerts.joinable()) alerts.join(); }
void Engine::poll() {
    while (!stopping) {
        session.wait_for_alert(std::chrono::milliseconds(100));
        std::vector<lt::alert *> pending;
        session.pop_alerts(&pending);
        for (auto *alert : pending) {
            auto *pieceAlert = lt::alert_cast<lt::read_piece_alert>(alert);
            auto *resumeAlert = lt::alert_cast<lt::save_resume_data_alert>(alert);
            if (!pieceAlert && !resumeAlert) continue;
            const auto handle = pieceAlert ? pieceAlert->handle : resumeAlert->handle;
            std::shared_ptr<Torrent> torrent;
            {
                std::lock_guard<std::mutex> lock(mutex);
                for (auto iterator = torrents.begin(); iterator != torrents.end();) {
                    auto item = *iterator;
                    if (item->removed) { iterator = torrents.erase(iterator); continue; }
                    if (item->handle == handle) torrent = item;
                    ++iterator;
                }
            }
            if (!torrent || torrent->removed) continue;
            if (auto *piece = lt::alert_cast<lt::read_piece_alert>(alert)) {
                std::lock_guard<std::mutex> lock(torrent->mutex);
                const int index = static_cast<int>(piece->piece);
                torrent->requested.erase(index);
                if (!piece->error && piece->size > 0 && torrent->cacheEnabled) {
                    // The cache is bounded independently of piece size; an active read keeps its own copy.
                    while (!torrent->pieces.empty() && torrent->cachedBytes + size_t(piece->size) > 32 * 1024 * 1024) {
                        torrent->cachedBytes -= torrent->pieces.begin()->second.size();
                        torrent->pieces.erase(torrent->pieces.begin());
                    }
                    torrent->pieces[index] = std::vector<char>(piece->buffer.get(), piece->buffer.get() + piece->size);
                    torrent->cachedBytes += piece->size;
                }
                torrent->condition.notify_all();
            }
            if (auto *resume = lt::alert_cast<lt::save_resume_data_alert>(alert)) {
                auto data = lt::write_resume_data_buf(resume->params);
                const auto temp = torrent->directory + "/.resume.tmp";
                std::ofstream file(temp, std::ios::binary | std::ios::trunc);
                file.write(data.data(), data.size());
                file.close();
                if (file) { std::error_code ec; std::filesystem::rename(temp, torrent->directory + "/.resume", ec); }
            }
        }
    }
}
void message(char *buffer, size_t capacity, const char *text) {
    if (buffer && capacity) std::snprintf(buffer, capacity, "%s", text);
}
}
struct ANITEngine { std::shared_ptr<Engine> value; };
struct ANITTorrent { std::shared_ptr<Torrent> value; std::shared_ptr<Engine> engine; };
struct ANITReadToken { std::atomic<bool> cancelled{false}; };

extern "C" ANITEngine *ANITCreateEngine(char *error, size_t capacity) {
    try { return new ANITEngine{std::make_shared<Engine>()}; }
    catch (const std::exception &) { message(error, capacity, "Cannot start BitTorrent engine"); return nullptr; }
}
extern "C" void ANITDestroyEngine(ANITEngine *engine) { delete engine; }
extern "C" int32_t ANITListenPort(ANITEngine *engine) {
    try { return engine ? engine->value->session.listen_port() : 0; } catch (...) { return 0; }
}
static ANITTorrent *add(ANITEngine *engine, lt::add_torrent_params params, const char *directory) {
    if (!engine || !directory) return nullptr;
    {
        std::lock_guard<std::mutex> lock(engine->value->mutex);
        for (const auto &existing : engine->value->torrents) {
            if (!existing || existing->removed) continue;
            const auto hashes = existing->handle.info_hashes();
            if ((hashes.has_v1() && params.info_hashes.has_v1() && hashes.v1 == params.info_hashes.v1)
                || (hashes.has_v2() && params.info_hashes.has_v2() && hashes.v2 == params.info_hashes.v2))
                return new ANITTorrent{existing, engine->value};
        }
    }
    const auto hashes = params.info_hashes;
    const std::string rawHash = hashes.has_v1() ? hashes.v1.to_string() : hashes.v2.to_string();
    std::string hashName = hashes.has_v1() ? "v1-" : "v2-";
    const char *hex = "0123456789abcdef";
    for (unsigned char byte : rawHash) { hashName += hex[byte >> 4]; hashName += hex[byte & 15]; }
    const auto saveDirectory = std::string(directory) + "/" + hashName;
    std::filesystem::create_directories(saveDirectory);
    std::ifstream file(saveDirectory + "/.resume", std::ios::binary);
    if (file) {
        std::vector<char> bytes((std::istreambuf_iterator<char>(file)), {});
        lt::error_code error;
        auto saved = lt::read_resume_data(bytes, error);
        if (!error && saved.info_hashes == params.info_hashes) params = std::move(saved);
    }
    params.save_path = saveDirectory;
    params.flags &= ~lt::torrent_flags::auto_managed;
    params.flags &= ~lt::torrent_flags::paused;
    params.flags |= lt::torrent_flags::duplicate_is_error;
    if (params.ti) params.file_priorities.assign(params.ti->num_files(), lt::dont_download);
    auto result = std::make_shared<Torrent>();
    result->engine = engine->value;
    result->directory = saveDirectory;
    result->handle = engine->value->session.add_torrent(std::move(params));
    {
        std::lock_guard<std::mutex> lock(engine->value->mutex);
        engine->value->torrents.push_back(result);
    }
    return new ANITTorrent{result, engine->value};
}
extern "C" ANITTorrent *ANITAddMagnet(ANITEngine *engine, const char *uri, const char *directory, char *error, size_t capacity) {
    try { if (!uri) return nullptr; return add(engine, lt::parse_magnet_uri(uri), directory); }
    catch (const std::exception &) { message(error, capacity, "Cannot add magnet link"); return nullptr; }
}
extern "C" ANITTorrent *ANITAddTorrent(ANITEngine *engine, const uint8_t *data, size_t size, const char *directory, char *error, size_t capacity) {
    try {
        if (!data || size == 0 || size > 32 * 1024 * 1024) return nullptr;
        lt::add_torrent_params params;
        params.ti = std::make_shared<lt::torrent_info>(reinterpret_cast<const char *>(data), int(size));
        params.info_hashes = params.ti->info_hashes();
        return add(engine, std::move(params), directory);
    } catch (const std::exception &) { message(error, capacity, "Invalid torrent metadata"); return nullptr; }
}
extern "C" void ANITCloseTorrent(ANITTorrent *torrent) { delete torrent; }
extern "C" int32_t ANITCopyMagnetURI(ANITTorrent *torrent, char *buffer, size_t capacity) {
    try {
        if (!torrent || torrent->value->removed || !buffer) return 0;
        const auto uri = lt::make_magnet_uri(torrent->value->handle);
        if (uri.empty() || uri.size() + 1 > capacity) return 0;
        message(buffer, capacity, uri.c_str()); return 1;
    } catch (...) { return 0; }
}
extern "C" int32_t ANITFileCount(ANITTorrent *torrent) {
    try {
        if (!torrent || torrent->value->removed) return -1;
        auto info = torrent->value->handle.torrent_file();
        if (!info) return -1;
        if (!torrent->value->configured.exchange(true))
            torrent->value->handle.prioritize_files(std::vector<lt::download_priority_t>(info->num_files(), lt::dont_download));
        return info->num_files();
    } catch (...) { return -1; }
}
extern "C" int32_t ANITFileInfo(ANITTorrent *torrent, int32_t index, char *path, size_t capacity, int64_t *size) {
    try {
        auto info = torrent->value->handle.torrent_file();
        if (!info || index < 0 || index >= info->num_files() || info->files().pad_file_at(lt::file_index_t(index))) return 0;
        auto name = info->files().file_path(lt::file_index_t(index));
        if (name.size() + 1 > capacity) return 0;
        message(path, capacity, name.c_str());
        if (size) *size = info->files().file_size(lt::file_index_t(index));
        return 1;
    } catch (...) { return 0; }
}
extern "C" int32_t ANITSelectFile(ANITTorrent *torrent, int32_t index) {
    try {
        if (ANITFileCount(torrent) <= index || index < 0) return 0;
        torrent->value->handle.file_priority(lt::file_index_t(index), lt::default_priority);
        torrent->value->handle.set_flags(lt::torrent_flags::sequential_download);
        return 1;
    } catch (...) { return 0; }
}
extern "C" ANITStatus ANITGetStatus(ANITTorrent *torrent) {
    ANITStatus result{};
    try {
        if (!torrent || torrent->value->removed) { result.failed = 1; return result; }
        const auto status = torrent->value->handle.status();
        result.wanted = status.total_wanted;
        result.completed = status.total_wanted_done;
        result.download_rate = status.download_payload_rate;
        result.upload_rate = status.upload_payload_rate;
        result.peers = status.num_peers;
        result.paused = bool(status.flags & lt::torrent_flags::paused);
        result.metadata_ready = status.has_metadata;
        result.failed = bool(status.errc);
    } catch (...) { result.failed = 1; }
    return result;
}
extern "C" void ANITSetPaused(ANITTorrent *torrent, int32_t paused) {
    try { if (paused) torrent->value->handle.pause(); else torrent->value->handle.resume(); } catch (...) {}
}
extern "C" void ANITSaveResume(ANITTorrent *torrent) {
    try { torrent->value->handle.save_resume_data(lt::torrent_handle::save_info_dict); } catch (...) {}
}
extern "C" void ANITTrimReadCache(ANITTorrent *torrent) {
    if (!torrent) return;
    auto value = torrent->value;
    std::lock_guard<std::mutex> lock(value->mutex);
    value->cacheEnabled = false;
    value->pieces.clear(); value->cachedBytes = 0;
}
extern "C" void ANITRemove(ANITTorrent *torrent, int32_t delete_files) {
    if (!torrent) return;
    auto value = torrent->value;
    if (value->removed.exchange(true)) return;
    std::error_code ignored;
    std::filesystem::remove(value->directory + "/.resume", ignored);
    std::filesystem::remove(value->directory + "/.resume.tmp", ignored);
    value->condition.notify_all();
    try { torrent->engine->session.remove_torrent(value->handle, delete_files ? lt::session::delete_files : lt::remove_flags_t{}); } catch (...) {}
}
extern "C" ANITReadToken *ANITCreateReadToken() { return new ANITReadToken; }
extern "C" void ANITCancelRead(ANITReadToken *token) { if (token) token->cancelled = true; }
extern "C" void ANITDestroyReadToken(ANITReadToken *token) { delete token; }
extern "C" int32_t ANITRead(ANITTorrent *torrent, int32_t index, int64_t offset, uint8_t *destination,
                              int32_t capacity, int32_t timeout_milliseconds, ANITReadToken *token) {
    try {
        if (!torrent || !destination || capacity <= 0 || offset < 0) return -1;
        auto value = torrent->value;
        value->cacheEnabled = true;
        auto info = value->handle.torrent_file();
        if (!info || index < 0 || index >= info->num_files()) return -1;
        const auto size = info->files().file_size(lt::file_index_t(index));
        if (offset >= size) return 0;
        const int64_t absolute = info->files().file_offset(lt::file_index_t(index)) + offset;
        const int piece = int(absolute / info->piece_length());
        const int in_piece = int(absolute % info->piece_length());
        value->handle.resume();
        for (int ahead = 0; ahead < 4 && piece + ahead < info->num_pieces(); ++ahead)
            value->handle.set_piece_deadline(lt::piece_index_t(piece + ahead), ahead * 100);
        const auto deadline = std::chrono::steady_clock::now() + std::chrono::milliseconds(std::max(1, timeout_milliseconds));
        std::unique_lock<std::mutex> lock(value->mutex);
        while (true) {
            if (value->removed || (token && token->cancelled)) return -2;
            auto found = value->pieces.find(piece);
            if (found != value->pieces.end()) {
                const int count = int(std::min<int64_t>({capacity, size - offset, int64_t(found->second.size()) - in_piece}));
                if (count <= 0) return -1;
                std::copy_n(found->second.data() + in_piece, count, destination);
                return count;
            }
            if (std::chrono::steady_clock::now() >= deadline) return -3;
            if (!value->requested.count(piece) && value->handle.have_piece(lt::piece_index_t(piece))) {
                value->requested.insert(piece);
                value->handle.read_piece(lt::piece_index_t(piece));
            }
            value->condition.wait_for(lock, std::chrono::milliseconds(25));
        }
    } catch (...) { return -1; }
}
