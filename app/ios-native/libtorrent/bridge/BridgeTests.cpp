#include "AniTorrentBridge.h"
#include <libtorrent/bencode.hpp>
#include <libtorrent/create_torrent.hpp>
#include <libtorrent/file_storage.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/torrent_info.hpp>
#include <cassert>
#include <chrono>
#include <filesystem>
#include <fstream>
#include <thread>
#include <vector>

int main(int argc, char **argv) {
    assert(argc == 2);
    const std::filesystem::path root(argv[1]);
    std::filesystem::create_directories(root / "fixture");
    std::vector<char> expected(300000);
    for (size_t i = 0; i < expected.size(); ++i) expected[i] = char(i % 251);
    std::ofstream output(root / "fixture" / "episode-01.mkv", std::ios::binary);
    output.write(expected.data(), expected.size()); output.close();
    libtorrent::file_storage files;
    libtorrent::add_files(files, (root / "fixture").string());
    libtorrent::create_torrent creator(files, 16384);
    libtorrent::set_piece_hashes(creator, root.string());
    std::vector<char> metadata;
    libtorrent::bencode(std::back_inserter(metadata), creator.generate());
    char error[256]{};
    auto *engine = ANITCreateEngine(error, sizeof error); assert(engine);
    libtorrent::settings_pack seedSettings;
    seedSettings.set_bool(libtorrent::settings_pack::enable_dht, false);
    seedSettings.set_bool(libtorrent::settings_pack::enable_lsd, false);
    seedSettings.set_str(libtorrent::settings_pack::listen_interfaces, "127.0.0.1:0");
    libtorrent::session seedSession(seedSettings);
    libtorrent::add_torrent_params seedParams;
    seedParams.ti = std::make_shared<libtorrent::torrent_info>(metadata.data(), int(metadata.size()));
    seedParams.save_path = root.string();
    seedParams.flags |= libtorrent::torrent_flags::seed_mode;
    seedParams.flags &= ~libtorrent::torrent_flags::paused;
    seedParams.flags &= ~libtorrent::torrent_flags::auto_managed;
    auto seed = seedSession.add_torrent(std::move(seedParams));
    std::filesystem::create_directories(root / "download");
    auto *torrent = ANITAddTorrent(engine, reinterpret_cast<uint8_t *>(metadata.data()), metadata.size(),
                                   (root / "download").string().c_str(), error, sizeof error); assert(torrent);
    for (int i = 0; i < 100 && ANITListenPort(engine) == 0; ++i) std::this_thread::sleep_for(std::chrono::milliseconds(25));
    assert(ANITListenPort(engine) > 0);
    seed.connect_peer(libtorrent::tcp::endpoint(libtorrent::make_address("127.0.0.1"), ANITListenPort(engine)));
    assert(ANITFileCount(torrent) == 1);
    auto *duplicate = ANITAddTorrent(engine, reinterpret_cast<uint8_t *>(metadata.data()), metadata.size(),
        (root / "download").string().c_str(), error, sizeof error);
    assert(duplicate);
    ANITCloseTorrent(duplicate);
    char path[4096]{}; int64_t size = 0;
    assert(ANITFileInfo(torrent, 0, path, sizeof path, &size) == 1 && size == 300000);
    assert(ANITSelectFile(torrent, 0) == 1);
    uint8_t bytes[4096]{};
    auto *token = ANITCreateReadToken();
    int count = ANITRead(torrent, 0, 16370, bytes, sizeof bytes, 10000, token);
    std::printf("piece length=%d first read=%d\n", creator.piece_length(), count); std::fflush(stdout); assert(count > 0 && count <= 14);
    for (int i = 0; i < count; ++i) assert(bytes[i] == uint8_t(expected[16370 + i]));
    count = ANITRead(torrent, 0, 299900, bytes, sizeof bytes, 10000, token);
    assert(count == 100);
    for (int i = 0; i < count; ++i) assert(bytes[i] == uint8_t(expected[299900 + i]));
    assert(ANITRead(torrent, 0, 300000, bytes, sizeof bytes, 100, token) == 0);
    ANITCancelRead(token);
    assert(ANITRead(torrent, 0, 0, bytes, sizeof bytes, 100, token) == -2);
    ANITDestroyReadToken(token);
    ANITSetPaused(torrent, 1);
    ANITSaveResume(torrent);
    bool saved = false;
    for (int i = 0; i < 100 && !saved; ++i) {
        for (const auto &item : std::filesystem::recursive_directory_iterator(root / "download"))
            if (item.path().filename() == ".resume") saved = true;
        std::this_thread::sleep_for(std::chrono::milliseconds(25));
    }
    assert(saved);
    ANITTrimReadCache(torrent);
    ANITRemove(torrent, 0);
    ANITCloseTorrent(torrent);
    ANITDestroyEngine(engine);
    std::puts("PASS: verified piece reads, tail seek, EOF, cancellation, resume persistence");
}
