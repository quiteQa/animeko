import AniCore
import SwiftUI

/// 一起看面板: 未加入时输入房间名与密码 (房间不存在则创建); 加入后显示成员, 跟随房主开关与离开.
struct WatchTogetherSheet: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            content
                .navigationTitle("一起看")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("完成", systemImage: "checkmark") { dismiss() }
                    }
                }
        }
    }

    @ViewBuilder
    private var content: some View {
        let room = services.watchTogether.room
        if !services.isLoggedIn {
            ContentUnavailableView(
                "登录后使用一起看",
                systemImage: "person.2",
                description: Text("在「我的」中登录 Bangumi 账号后, 可以与好友同步观看."),
            )
        } else if room?.status == .inRoom, let room {
            WatchTogetherRoomView(room: room)
        } else {
            WatchTogetherJoinForm(status: room?.status)
        }
    }
}

private struct WatchTogetherJoinForm: View {
    let status: AniWatchTogetherStatus?

    @Environment(AppServices.self) private var services
    @State private var roomName = ""
    @State private var password = ""
    @State private var error: String?
    @State private var isJoining = false

    var body: some View {
        Form {
            Section {
                TextField("房间名", text: $roomName)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                SecureField("密码", text: $password)
            } footer: {
                Text("与好友输入相同的房间名和密码即可进入同一房间; 房间不存在时自动创建, 创建者成为房主.")
            }

            if let error {
                Section {
                    Label(error, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
                }
            }

            Section {
                Button {
                    join()
                } label: {
                    HStack {
                        Spacer()
                        if isJoining || status == .joining {
                            ProgressView()
                        } else {
                            Text("加入或创建房间").fontWeight(.semibold)
                        }
                        Spacer()
                    }
                }
                .disabled(roomName.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty || isJoining)
            }
        }
        .task {
            if roomName.isEmpty {
                roomName = (try? await services.core.watchTogether.lastRoomName()) ?? ""
            }
        }
    }

    private func join() {
        isJoining = true
        error = nil
        let core = services.core
        Task {
            defer { isJoining = false }
            do {
                // 功能开启后 Kotlin 侧需要片刻进入可加入状态
                if status == .disabled || status == nil {
                    try await core.watchTogether.enable()
                    try? await Task.sleep(for: .milliseconds(300))
                }
                error = try await core.watchTogether.join(roomName: roomName, password: password)
            } catch {
                self.error = "加入失败: \(error.localizedDescription)"
            }
        }
    }
}

private struct WatchTogetherRoomView: View {
    let room: AniWatchTogetherRoom

    @Environment(AppServices.self) private var services

    var body: some View {
        List {
            Section {
                LabeledContent("房间", value: room.roomName)
                LabeledContent("身份", value: room.isHost ? "房主" : "成员")
                LabeledContent("连接") {
                    Label(connectionText, systemImage: connectionIcon)
                        .foregroundStyle(room.connection == .connected ? .green : .orange)
                }
                if let host = room.hostWatching {
                    LabeledContent("房主在看", value: "\(host.subjectName) 第 \(host.episodeSort) 话")
                }
            }

            if !room.isHost {
                Section {
                    Toggle("跟随房主", isOn: Binding(
                        get: { room.following },
                        set: { following in
                            Task { try? await services.core.watchTogether.setFollowing(following: following) }
                        },
                    ))
                } footer: {
                    Text("跟随时自动与房主同步剧集, 进度, 速度与播放状态.")
                }
            }

            Section("成员 (\(room.members.count))") {
                ForEach(room.members, id: \.userId) { member in
                    MemberRow(member: member)
                }
            }

            Section {
                Button("离开房间", role: .destructive) {
                    Task { try? await services.core.watchTogether.leave() }
                }
            }
        }
    }

    private var connectionText: String {
        switch room.connection {
        case .connected: "已连接"
        case .reconnecting: "正在重连"
        case .polling: "网络较差, 低频同步"
        default: "未连接"
        }
    }

    private var connectionIcon: String {
        room.connection == .connected ? "dot.radiowaves.left.and.right" : "wifi.exclamationmark"
    }
}

private struct MemberRow: View {
    let member: AniWatchTogetherMemberInfo

    var body: some View {
        HStack(spacing: 12) {
            AsyncImage(url: URL(string: member.avatarUrl)) { image in
                image.resizable().scaledToFill()
            } placeholder: {
                Image(systemName: "person.crop.circle.fill")
                    .resizable()
                    .foregroundStyle(.secondary)
            }
            .frame(width: 36, height: 36)
            .clipShape(.circle)
            .overlay(alignment: .bottomTrailing) {
                Circle()
                    .fill(member.online ? .green : .gray)
                    .frame(width: 10, height: 10)
                    .overlay(Circle().stroke(Color(.systemBackground), lineWidth: 2))
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(member.nickname).font(.body.weight(.medium)).lineLimit(1)
                    if member.isHost {
                        Text("房主")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.tint.opacity(0.18), in: .capsule)
                    } else if member.following {
                        Text("跟随中").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                Text(watchingText).font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
        }
    }

    private var watchingText: String {
        guard member.online else { return "离线" }
        guard let watching = member.watching else { return "未在播放" }
        return "\(watching.paused ? "暂停" : "正在看") \(watching.subjectName) 第 \(watching.episodeSort) 话"
    }
}
