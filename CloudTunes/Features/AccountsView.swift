import SwiftUI

/// 网盘账号管理页
struct AccountsView: View {
    @State private var refresh = false

    var body: some View {
        NavigationStack {
            List {
                ForEach(CloudKind.allCases) { kind in
                    NavigationLink {
                        providerDetail(kind: kind)
                    } label: {
                        accountRow(kind)
                    }
                }
            }
            .navigationTitle("我的网盘")
            .id(refresh)
        }
    }

    @ViewBuilder
    private func providerDetail(kind: CloudKind) -> some View {
        switch kind {
        case .guangya: GuangyaLoginView()
        case .baidu: BaiduLoginView()
        case .quark: QuarkLoginView()
        }
    }

    private func accountRow(_ kind: CloudKind) -> some View {
        HStack {
            Image(systemName: kind.icon).frame(width: 30)
            VStack(alignment: .leading) {
                Text(kind.rawValue)
                let p = ProviderRegistry.provider(kind: kind)
                Text(p?.isSignedIn == true ? "已登录 · \(p?.displayName ?? "")" : "未登录")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }
}

/// 光鸭：手机号 + 短信验证码登录
struct GuangyaLoginView: View {
    @StateObject private var provider = ProviderRegistry.guangya
    @State private var phone = ""
    @State private var code = ""
    @State private var verificationID: String?
    @State private var status = ""
    @State private var clientIDDraft = CredentialStore.get("guangya.clientID") ?? ""

    var body: some View {
        Form {
            Section("Client ID（网页版 F12 → 请求头 X-Client-Id，见 README）") {
                TextField("网页端 Client ID", text: $clientIDDraft)
                    .autocorrectionDisabled()
                    .onChange(of: clientIDDraft) { CredentialStore.set($1, for: "guangya.clientID") }
            }
            if provider.isSignedIn {
                Section {
                    Text("已登录：\(provider.displayName ?? "")")
                    Button("退出登录", role: .destructive) { provider.signOut() }
                }
                NavigationLink("浏览文件 →") { FileBrowserView(kind: .guangya) }
            } else {
                Section("手机号") {
                    TextField("+8613800138000", text: $phone)
                        .keyboardType(.phonePad)
                    Button("发送验证码") { sendCode() }
                        .disabled(phone.isEmpty || verificationID != nil)
                }
                if verificationID != nil {
                    Section("短信验证码") {
                        TextField("6 位验证码", text: $code).keyboardType(.numberPad)
                        Button("登录") { signIn() }.disabled(code.count < 4)
                    }
                }
            }
            if !status.isEmpty {
                Section { Text(status).font(.footnote).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("光鸭云盘")
    }

    private func sendCode() {
        status = "正在发送验证码…"
        Task {
            do {
                verificationID = try await provider.sendCode(phoneE164: phone)
                status = "验证码已发送，请查收短信"
            } catch {
                status = "发送失败：\(error.localizedDescription)"
            }
        }
    }

    private func signIn() {
        status = "登录中…"
        Task {
            do {
                try await provider.signIn(phoneE164: phone, verificationID: verificationID!, code: code)
                status = "登录成功"
            } catch {
                status = "登录失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 百度：引导注册开放平台 + oob 授权码登录
struct BaiduLoginView: View {
    @StateObject private var provider = ProviderRegistry.baidu
    @State private var appKey = CredentialStore.get("baidu.appKey") ?? ""
    @State private var secretKey = CredentialStore.get("baidu.secretKey") ?? ""
    @State private var authCode = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section("开放平台应用（pan.baidu.com/union 创建应用）") {
                TextField("AppKey", text: $appKey).autocorrectionDisabled()
                    .onChange(of: appKey) { CredentialStore.set($1, for: "baidu.appKey") }
                SecureField("SecretKey", text: $secretKey).autocorrectionDisabled()
                    .onChange(of: secretKey) { CredentialStore.set($1, for: "baidu.secretKey") }
            }
            if provider.isSignedIn {
                Section {
                    Text("已登录：\(provider.displayName ?? "")")
                    Button("退出登录", role: .destructive) { provider.signOut() }
                }
                NavigationLink("浏览文件 →") { FileBrowserView(kind: .baidu) }
            } else {
                Section("授权") {
                    Link("1. 打开授权页，登录后复制授权码", destination: BaiduProvider.authorizeURL)
                    TextField("2. 粘贴授权码", text: $authCode).autocorrectionDisabled()
                    Button("3. 登录") { login() }.disabled(authCode.isEmpty)
                }
            }
            if !status.isEmpty {
                Section { Text(status).font(.footnote).foregroundColor(.secondary) }
            }
        }
        .navigationTitle("百度网盘")
    }

    private func login() {
        status = "登录中…"
        Task {
            do {
                try await provider.exchangeCode(authCode.trimmingCharacters(in: .whitespaces))
                status = "登录成功"
            } catch {
                status = "登录失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 夸克：粘贴网页版 Cookie（实验性）
struct QuarkLoginView: View {
    @StateObject private var provider = ProviderRegistry.quark
    @State private var cookie = ""

    var body: some View {
        Form {
            if provider.isSignedIn {
                Section {
                    Text("已导入 Cookie")
                    Button("退出登录", role: .destructive) { provider.signOut() }
                }
                NavigationLink("浏览文件 →") { FileBrowserView(kind: .quark) }
            } else {
                Section("Cookie（网页版 pan.quark.cn → F12 → Network → 任意请求的 Cookie 全量复制）") {
                    TextEditor(text: $cookie).frame(minHeight: 120)
                        .font(.system(size: 12, design: .monospaced))
                    Button("导入并登录") {
                        provider.setCookie(cookie.trimmingCharacters(in: .whitespacesAndNewlines))
                    }
                }
            }
            Section {
                Text("⚠️ 夸克官方未开放 API，本功能基于社区逆向接口，可能随时失效或触发账号风控，请自行斟酌。")
                    .font(.footnote).foregroundColor(.orange)
            }
        }
        .navigationTitle("夸克网盘")
    }
}
