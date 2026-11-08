import AniCore
import SwiftUI

/// 设置. 读写上游的同一份设置; 修改立即保存, 值通过 `AppServices.settings` 回流.
struct SettingsScreen: View {
    @Environment(AppServices.self) private var services
    @State private var errorMessage: String?

    private var store: AniSettingsStore { services.core.settings }

    var body: some View {
        Form {
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
            NavigationLink {
                PikPakSettingsScreen()
            } label: {
                LabeledContent("PikPak 云离线", value: settings.pikpakEnabled ? settings.pikpakUsername : "未启用")
            }
        } header: {
            Text("选源")
        } footer: {
            Text("iOS 没有本地 BT 引擎; 配置 PikPak 后, BT 资源经云离线播放。")
        }
    }

    private func playbackSection(_ settings: AniSettings) -> some View {
        Section("播放") {
            Picker("HLS 去广告", selection: binding(settings.hlsAdFiltering) { try await store.setHlsAdFiltering(mode: $0) }) {
                Text("所有数据源").tag("ALL")
                Text("仅标记了广告的数据源").tag("SMART")
                Text("关闭").tag("OFF")
            }
            Toggle("看完 90% 自动标记看过", isOn: binding(settings.autoMarkDone) { try await store.setAutoMarkDone(value: $0) })
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
private struct MediaSourcesScreen: View {
    @Environment(AppServices.self) private var services
    @State private var sources: [AniMediaSourceItem] = []

    var body: some View {
        List(sources, id: \.instanceId) { source in
            Toggle(isOn: Binding(
                get: { source.enabled },
                set: { enabled in
                    Task { try? await services.core.settings.setMediaSourceEnabled(instanceId: source.instanceId, enabled: enabled) }
                },
            )) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(source.displayName)
                    Text(source.kind == "WEB" ? "在线" : source.kind == "BitTorrent" ? "BT" : source.kind)
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

private struct DanmakuFiltersScreen: View {
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

private struct PikPakSettingsScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var enabled = false
    @State private var username = ""
    @State private var password = ""
    @State private var errorMessage: String?
    @State private var initialized = false

    var body: some View {
        Form {
            Section {
                Toggle("启用 PikPak", isOn: $enabled)
                TextField("账号 (手机号或邮箱)", text: $username)
                    .textContentType(.username)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码 (留空则保持不变)", text: $password)
                    .textContentType(.password)
            } footer: {
                Text("BT 资源会提交到 PikPak 离线下载, 再从 PikPak 流式播放。账号只保存在本机。")
            }
            if let errorMessage {
                Section { Text(errorMessage).foregroundStyle(.red) }
            }
        }
        .navigationTitle("PikPak 云离线")
        .toolbar {
            ToolbarItem(placement: .confirmationAction) {
                Button("保存") { save() }
                    .disabled(enabled && username.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .onAppear {
            guard !initialized, let settings = services.settings else { return }
            initialized = true
            enabled = settings.pikpakEnabled
            username = settings.pikpakUsername
        }
    }

    private func save() {
        Task {
            do {
                try await services.core.settings.setPikPak(
                    enabled: enabled,
                    username: username.trimmingCharacters(in: .whitespaces),
                    password: password,
                )
                dismiss()
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }
}
