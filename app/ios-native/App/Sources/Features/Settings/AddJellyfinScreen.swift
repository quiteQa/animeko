import SwiftUI

struct AddJellyfinScreen: View {
    @Environment(AppServices.self) private var services
    @Environment(\.dismiss) private var dismiss
    @State private var server = ""
    @State private var usesPassword = true
    @State private var username = ""
    @State private var password = ""
    @State private var userID = ""
    @State private var apiKey = ""
    @State private var saving = false
    @State private var error: String?

    var body: some View {
        Form {
            Section("服务器") {
                TextField("https://jellyfin.example.com", text: $server)
                    .keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("认证") {
                Picker("方式", selection: $usesPassword) {
                    Text("用户名与密码").tag(true)
                    Text("User ID 与 API Key").tag(false)
                }
                if usesPassword {
                    TextField("用户名", text: $username).textContentType(.username)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("密码", text: $password).textContentType(.password)
                } else {
                    TextField("User ID", text: $userID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    SecureField("API Key", text: $apiKey)
                }
            }
            Section {
                Button {
                    saving = true; error = nil
                    Task {
                        do {
                            try await services.core.settings.addJellyfin(baseUrl: server,
                                username: usesPassword ? username : "", password: usesPassword ? password : "",
                                userId: usesPassword ? "" : userID, apiKey: usesPassword ? "" : apiKey)
                            dismiss()
                        } catch { self.error = "保存失败，请检查服务器地址与认证信息" }
                        saving = false
                    }
                } label: {
                    if saving { ProgressView() } else { Text("保存媒体库") }
                }.disabled(saving || server.trimmingCharacters(in: .whitespaces).isEmpty)
                if let error { Text(error).foregroundStyle(.red) }
            } footer: {
                Text("保存后会在自动选源和手动查找中查询此媒体库。登录和播放错误会显示在对应数据源的状态中。")
            }
        }.navigationTitle("添加 Jellyfin")
    }
}
