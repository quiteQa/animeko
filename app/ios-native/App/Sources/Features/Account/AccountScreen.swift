import AniCore
import SwiftUI

/// 「我的」: 账号卡片, 常用入口与常用设置. 常用设置直接在本页切换, 其余设置在「全部设置」中.
struct AccountScreen: View {
    @Environment(AppServices.self) private var services
    @State private var login = BangumiLoginModel()
    @State private var confirmingLogout = false
    @State private var errorMessage: String?
    @AppStorage(RootTab.launchTabKey) private var launchTab = RootTab.collection

    private var store: AniSettingsStore { services.core.settings }

    var body: some View {
        List {
            accountSection

            Section {
                HStack(spacing: 0) {
                    shortcut("缓存管理", systemImage: "arrow.down.circle") { DownloadsScreen() }
                    shortcut("数据源", systemImage: "server.rack") { MediaSourcesScreen() }
                    shortcut("屏蔽词", systemImage: "text.badge.xmark") { DanmakuFiltersScreen() }
                    shortcut("诊断日志", systemImage: "stethoscope") { DiagnosticsScreen() }
                }
                .listRowInsets(EdgeInsets(top: 12, leading: 8, bottom: 12, trailing: 8))
            }

            quickSettingsSection

            Section {
                NavigationLink {
                    SettingsScreen()
                } label: {
                    Label("全部设置", systemImage: "gearshape")
                }
            }

            if let message = login.errorMessage ?? errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            if services.session?.loggedIn == true {
                Section {
                    Button("退出登录", role: .destructive) { confirmingLogout = true }
                        .frame(maxWidth: .infinity)
                }
            }
        }
        .navigationTitle("我的")
        .bangumiLogin(login)
        .confirmationDialog("退出登录?", isPresented: $confirmingLogout, titleVisibility: .visible) {
            Button("退出登录", role: .destructive) {
                Task { try? await services.core.logout() }
            }
        }
    }

    // MARK: - 账号

    @ViewBuilder
    private var accountSection: some View {
        if let session = services.session {
            if session.loggedIn {
                Section {
                    HStack(spacing: 16) {
                        AsyncImage(url: URL(string: session.avatarUrl)) { image in
                            image.resizable().scaledToFill()
                        } placeholder: {
                            Image(systemName: "person.crop.circle.fill").resizable().foregroundStyle(.secondary)
                        }
                        .frame(width: 56, height: 56)
                        .clipShape(.circle)
                        .accessibilityHidden(true)
                        VStack(alignment: .leading, spacing: 4) {
                            Text(session.nickname.isEmpty ? "Ani 用户" : session.nickname)
                                .font(.headline)
                            Label(
                                session.bangumiConnected ? "已绑定 Bangumi" : "未绑定 Bangumi",
                                systemImage: session.bangumiConnected ? "checkmark.seal.fill" : "exclamationmark.circle",
                            )
                            .font(.footnote)
                            .foregroundStyle(session.bangumiConnected ? .green : .orange)
                        }
                    }
                    if !session.bangumiConnected {
                        loginButton(title: "绑定 Bangumi")
                    }
                } footer: {
                    if !session.bangumiConnected {
                        Text("绑定后可同步 Bangumi 收藏与观看进度。")
                    }
                }
            } else {
                Section {
                    loginButton(title: "使用 Bangumi 登录")
                } footer: {
                    Text("登录后可同步 Bangumi 收藏与观看进度。")
                }
            }
        } else {
            ProgressView().frame(maxWidth: .infinity)
        }
    }

    private func loginButton(title: String) -> some View {
        Button {
            login.start(core: services.core)
        } label: {
            HStack {
                Text(title)
                Spacer()
                if login.isRunning { ProgressView() }
            }
        }
        .disabled(login.isRunning)
    }

    // MARK: - 常用入口

    /// 一行四个的图标入口. 每个入口单独响应点按 (`.plain` 样式), 不会整行一起触发.
    private func shortcut<Destination: View>(
        _ title: String,
        systemImage: String,
        @ViewBuilder destination: @escaping () -> Destination,
    ) -> some View {
        NavigationLink {
            destination()
        } label: {
            VStack(spacing: 8) {
                Image(systemName: systemImage)
                    .font(.title3)
                    .foregroundStyle(.tint)
                    .frame(width: 48, height: 48)
                    .background(Color.accentColor.opacity(0.12), in: .circle)
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
    }

    // MARK: - 常用设置

    @ViewBuilder
    private var quickSettingsSection: some View {
        Section {
            if let settings = services.settings {
                Toggle(isOn: binding(settings.autoPlayNext) { try await store.setAutoPlayNext(value: $0) }) {
                    Label("自动播放下一集", systemImage: "forward.end")
                }
                Toggle(isOn: binding(settings.autoSkipOpEd) { try await store.setAutoSkipOpEd(value: $0) }) {
                    Label("自动跳过 OP/ED", systemImage: "forward")
                }
                Toggle(isOn: binding(settings.danmakuEnabled) { try await store.setDanmakuEnabled(value: $0) }) {
                    Label("默认显示弹幕", systemImage: "captions.bubble")
                }
                Toggle(isOn: binding(settings.preferWebSources) { try await store.setPreferWebSources(value: $0) }) {
                    Label("优先使用在线数据源", systemImage: "globe")
                }
            }
            Picker(selection: $launchTab) {
                ForEach(RootTab.allCases) { tab in
                    Text(tab.title).tag(tab)
                }
            } label: {
                Label("启动时打开", systemImage: "app.badge")
            }
        } header: {
            Text("常用设置")
        }
    }

    /// 读取当前值, 写入时调用 `save`; 失败时显示错误.
    private func binding<Value>(_ value: Value, save: @escaping (Value) async throws -> Void) -> Binding<Value> {
        Binding(
            get: { value },
            set: { newValue in
                Task {
                    do {
                        errorMessage = nil
                        try await save(newValue)
                    } catch {
                        errorMessage = error.localizedDescription
                    }
                }
            },
        )
    }
}
