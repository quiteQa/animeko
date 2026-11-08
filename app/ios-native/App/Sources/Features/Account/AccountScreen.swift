import AniCore
import SwiftUI

struct AccountScreen: View {
    @Environment(AppServices.self) private var services
    @State private var login = BangumiLoginModel()
    @State private var confirmingLogout = false

    var body: some View {
        List {
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
                    }
                    if !session.bangumiConnected {
                        Section {
                            loginButton(title: "绑定 Bangumi")
                        } footer: {
                            Text("绑定后可同步 Bangumi 收藏与观看进度。")
                        }
                    }
                    Section {
                        Button("退出登录", role: .destructive) { confirmingLogout = true }
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

            if let message = login.errorMessage {
                Section {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.red)
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
}
