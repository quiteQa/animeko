// libtorrent 在 iOS 上的冒烟测试 (M0). 由 CI 在模拟器中运行, 退出码 0 表示通过.
//
// 1. 创建会话并监听端口
// 2. 连上 DHT (路由表中有节点)
// 3. 通过 DHT 获取一个公开种子 (Big Buck Bunny) 的元数据; 网络受限时只报告, 不判失败
// 4. 启动 anitorrent 的 session_t, 证明上游 C++ 封装能在 iOS 上链接与运行

#include <chrono>
#include <cstdio>
#include <thread>

#include <libtorrent/alert_types.hpp>
#include <libtorrent/magnet_uri.hpp>
#include <libtorrent/session.hpp>
#include <libtorrent/session_params.hpp>
#include <libtorrent/settings_pack.hpp>
#include <libtorrent/version.hpp>

#include "session_t.hpp"

namespace lt = libtorrent;

int main(int argc, char **argv) {
    const char *dir = argc > 1 ? argv[1] : "/tmp/lt-smoke";
    std::printf("libtorrent %s\n", lt::version());

    lt::settings_pack pack;
    pack.set_str(lt::settings_pack::listen_interfaces, "0.0.0.0:0,[::]:0");
    pack.set_bool(lt::settings_pack::enable_dht, true);
    pack.set_int(lt::settings_pack::alert_mask,
                 lt::alert_category::status | lt::alert_category::error | lt::alert_category::dht);
    lt::session session(lt::session_params(std::move(pack)));

    lt::add_torrent_params params = lt::parse_magnet_uri(
        "magnet:?xt=urn:btih:dd8255ecdc7ca55fb0bbf81323d87062db1f6d1c&dn=Big+Buck+Bunny"
        "&tr=udp%3A%2F%2Ftracker.opentrackr.org%3A1337%2Fannounce"
        "&tr=udp%3A%2F%2Fexplodie.org%3A6969");
    params.save_path = dir;
    lt::torrent_handle handle = session.add_torrent(std::move(params));

    bool listening = false;
    bool metadata = false;
    int dhtNodes = 0;
    auto deadline = std::chrono::steady_clock::now() + std::chrono::seconds(90);
    while (std::chrono::steady_clock::now() < deadline && !(listening && metadata)) {
        session.wait_for_alert(std::chrono::seconds(1));
        std::vector<lt::alert *> alerts;
        session.pop_alerts(&alerts);
        for (lt::alert *a : alerts) {
            if (lt::alert_cast<lt::listen_succeeded_alert>(a)) listening = true;
            if (lt::alert_cast<lt::metadata_received_alert>(a)) metadata = true;
            if (lt::alert_cast<lt::listen_failed_alert>(a) || lt::alert_cast<lt::torrent_error_alert>(a)) {
                std::printf("alert: %s\n", a->message().c_str());
            }
            if (auto *stats = lt::alert_cast<lt::dht_stats_alert>(a)) {
                dhtNodes = 0;
                for (auto const &bucket : stats->routing_table) dhtNodes += bucket.num_nodes;
            }
        }
        session.post_dht_stats();
    }

    lt::torrent_status status = handle.status();
    std::printf("listening=%d dht_nodes=%d metadata=%d peers=%d\n",
                listening, dhtNodes, metadata, status.num_peers);

    // 上游封装: 用默认设置启动一个 anitorrent 会话
    {
        anilt::session_t wrapped;
        anilt::session_settings_t settings;
        wrapped.start(settings);
        wrapped.post_session_stats();
        std::printf("anitorrent session_t started\n");
    }

    if (!listening) {
        std::printf("FAIL: session did not listen\n");
        return 1;
    }
    if (dhtNodes == 0 && !metadata) {
        std::printf("FAIL: no DHT nodes and no metadata\n");
        return 2;
    }
    std::printf("PASS%s\n", metadata ? "" : " (metadata not received in time)");
    return 0;
}
