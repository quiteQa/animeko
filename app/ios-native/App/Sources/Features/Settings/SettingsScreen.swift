import AniCore
import SwiftUI

/// 设置. 读写上游的同一份设置; 修改立即保存, 值通过 `AppServices.settings` 回流.
struct SettingsScreen: View {
    @Environment(AppServices.self) private var services
    @State private var errorMessage: String?

    @AppStorage(RootTab.launchTabKey) private var launchTab = RootTab.collection

    private var store: AniSettingsStore { services.core.settings }

    var body: some View {
        Form {
            Section {
                Picker("启动时打开", selection: $launchTab) {
                    ForEach(RootTab.allCases) { tab in
                        Text(tab.title).tag(tab)
                    }
                }
            } header: {
                Text("通用")
            } footer: {
                Text("下次启动 App 时生效.")
            }
            if let settings = services.settings {
                sourceSection(settings)
                playbackSection(settings)
                danmakuSection(settings)
                Section("内容") {
                    Picker("NSFW 条目", selection: binding(settings.nsfwMode) { try await store.setNsfwMode(mode: $0) }) {
                        Text("隐藏").tag("HIDE")
                        Text("模糊").tag("BLUR")
                        Text("显示").tag("DISPLAY")
                    }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let errorMessage {
                Section {
                    Label(errorMessage, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                }
            }
            Section {
                NavigationLink("诊断日志") { DiagnosticsScreen() }
            } footer: {
                Text("记录播放器启动的各个步骤与崩溃信息, 闪退后可在这里查看并分享.")
            }
        }
        .navigationTitle("设置")
    }

    private func sourceSection(_ settings: AniSettings) -> some View {
        Section {
            Toggle("优先使用在线数据源", isOn: binding(settings.preferWebSources) { try await store.setPreferWebSources(value: $0) })
            Toggle("在线数据源快速选择", isOn: binding(settings.fastSelectWeb) { try await store.setFastSelectWeb(value: $0) })
            Toggle("自动启用上次使用的数据源", isOn: binding(settings.autoEnableLastSelected) {
                try await store.setAutoEnableLastSelected(value: $0)
            })
            NavigationLink("数据源") { MediaSourcesScreen() }
        } header: {
            Text("选源")
        }
    }

    private func playbackSection(_ settings: AniSettings) -> some View {
        Section {
            Picker("HLS 去广告", selection: binding(settings.hlsAdFiltering) { try await store.setHlsAdFiltering(mode: $0) }) {
                Text("所有数据源").tag("ALL")
                Text("仅标记了广告的数据源").tag("SMART")
                Text("关闭").tag("OFF")
            }
            Picker("默认画质增强", selection: binding(settings.videoEnhancementDefaultMode) {
                try await store.setVideoEnhancementDefaultMode(mode: $0)
            }) {
                ForEach(VideoEnhancementMode.menuOrder) { mode in
                    Text(mode.title).tag(mode.settingValue)
                }
            }
            Toggle("看完 90% 自动标记看过", isOn: binding(settings.autoMarkDone) { try await store.setAutoMarkDone(value: $0) })
            Toggle("自动跳过 OP/ED", isOn: binding(settings.autoSkipOpEd) { try await store.setAutoSkipOpEd(value: $0) })
            Toggle("自动播放下一集", isOn: binding(settings.autoPlayNext) { try await store.setAutoPlayNext(value: $0) })
        } header: {
            Text("播放")
        } footer: {
            Text("自动跳过的位置来自其他用户手动跳过 OP/ED 的统计; 在播放页点击跳过按钮也会参与统计。")
        }
    }

    private func danmakuSection(_ settings: AniSettings) -> some View {
        Section("弹幕") {
            Toggle("默认显示弹幕", isOn: binding(settings.danmakuEnabled) { try await store.setDanmakuEnabled(value: $0) })
            Toggle("滚动弹幕", isOn: visibility(settings, \.floating))
            Toggle("顶部弹幕", isOn: visibility(settings, \.top))
            Toggle("底部弹幕", isOn: visibility(settings, \.bottom))
            Toggle("彩色弹幕", isOn: visibility(settings, \.color))
            Picker("文字转换", selection: binding(settings.danmakuTextConversion) {
                try await store.setDanmakuTextConversion(target: $0)
            }) {
                Text("原文").tag("ORIGINAL")
                Text("简体").tag("SIMPLIFIED")
                Text("繁体").tag("TRADITIONAL")
                Text("台湾正体").tag("TAIWAN")
                Text("香港繁体").tag("HONG_KONG")
            }
            NavigationLink("屏蔽词") { DanmakuFiltersScreen() }
        }
    }

    // MARK: - 绑定

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

    private struct DanmakuVisibility {
        var top: Bool
        var bottom: Bool
        var floating: Bool
        var color: Bool
    }

    private func visibility(_ settings: AniSettings, _ keyPath: WritableKeyPath<DanmakuVisibility, Bool>) -> Binding<Bool> {
        let current = DanmakuVisibility(
            top: settings.danmakuShowTop,
            bottom: settings.danmakuShowBottom,
            floating: settings.danmakuShowFloating,
            color: settings.danmakuShowColor,
        )
        return binding(current[keyPath: keyPath]) { newValue in
            var updated = current
            updated[keyPath: keyPath] = newValue
            try await store.setDanmakuVisibility(
                top: updated.top,
                bottom: updated.bottom,
                floating: updated.floating,
                color: updated.color,
            )
        }
    }
}

/// 数据源列表: 启用或停用. 数据源由订阅自动维护, 这里不增删.
struct MediaSourcesScreen: View {
    @Environment(AppServices.self) private var services
    @State private var sources: [AniMediaSourceItem] = []

    /// iOS 上的查询会话不包含 BT 数据源 (上游 `MediaSourceManager` 在 iOS 上关闭了 BT 查询), 不列出它们.
    private var visibleSources: [AniMediaSourceItem] {
        sources.filter { $0.kind != "BitTorrent" }
    }

    var body: some View {
        List(visibleSources, id: \.instanceId) { source in
            Toggle(isOn: Binding(
                get: { source.enabled },
                set: { enabled in
                    Task { try? await services.core.settings.setMediaSourceEnabled(instanceId: source.instanceId, enabled: enabled) }
                },
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                    Text(source.kind == "WEB" ? "在线" : source.kind)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .navigationTitle("数据源")
        .task {
            for await list in services.core.settings.mediaSourceUpdates { sources = list }
        }
    }
}

struct DanmakuFiltersScreen: View {
    @Environment(AppServices.self) private var services
    @State private var filters: [AniDanmakuFilter] = []
    @State private var newRegex = ""
    @State private var errorMessage: String?

    var body: some View {
        List {
            Section {
                HStack {
                    TextField("正则表达式, 如 剧透|前方高能", text: $newRegex)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("添加") { add() }
                        .disabled(newRegex.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } footer: {
                if let errorMessage {
                    Text(errorMessage).foregroundStyle(.red)
                } else {
                    Text("匹配任意一条屏蔽词的弹幕不会显示, 不区分大小写。")
                }
            }
            Section {
                ForEach(filters, id: \.id) { filter in
                    Toggle(filter.regex, isOn: Binding(
                        get: { filter.enabled },
                        set: { enabled in
                            Task { try? await services.core.settings.setDanmakuFilterEnabled(id: filter.id, enabled: enabled) }
                        },
                    ))
                }
                .onDelete { offsets in
                    let ids = offsets.map { filters[$0].id }
                    Task {
                        for id in ids { try? await services.core.settings.removeDanmakuFilter(id: id) }
                    }
                }
            }
        }
        .navigationTitle("屏蔽词")
        .toolbar { EditButton() }
        .task {
            for await list in services.core.settings.danmakuFilterUpdates { filters = list }
        }
    }

    private func add() {
        let regex = newRegex.trimmingCharacters(in: .whitespaces)
        Task {
            do {
                try await services.core.settings.addDanmakuFilter(regex: regex)
                newRegex = ""
                errorMessage = nil
            } catch {
                errorMessage = "不是有效的正则表达式"
            }
        }
    }
}
