import SwiftUI

/// 网盘账号一行（供「我的」页使用）
struct ProviderRow: View {
    let kind: CloudKind

    var body: some View {
        HStack(spacing: 12) {
            Group {
                if let ui = UIImage(named: kind.brandIconName) {
                    Image(uiImage: ui).resizable().scaledToFill()
                } else {
                    ZStack {
                        color.opacity(0.15)
                        Image(systemName: kind.icon)
                            .font(.system(size: 16, weight: .medium))
                            .foregroundStyle(color)
                    }
                }
            }
            .frame(width: 38, height: 38)
            .clipShape(RoundedRectangle(cornerRadius: 9, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 0.5)
            )

            VStack(alignment: .leading, spacing: 2) {
                Text(kind.rawValue).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
                let p = ProviderRegistry.provider(kind: kind)
                Text(p?.isSignedIn == true ? "已登录 · \(p?.displayName ?? "")" : "未登录")
                    .font(.caption)
                    .foregroundStyle(p?.isSignedIn == true ? Color.green : Color.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.quaternary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var color: Color {
        switch kind {
        case .guangya: return Theme.accent
        case .baidu: return Color(red: 0.30, green: 0.48, blue: 0.98)
        case .quark: return Color(red: 0.35, green: 0.62, blue: 0.98)
        }
    }
}

/// 光鸭：手机号 + 短信验证码登录
struct GuangyaLoginView: View {
    private let provider = ProviderRegistry.guangya
    @State private var signedIn = ProviderRegistry.guangya.isSignedIn
    @State private var phone = ""
    @State private var code = ""
    @State private var verificationID: String?
    @State private var status = ""
    @State private var clientIDDraft = CredentialStore.get("guangya.clientID") ?? ""

    var body: some View {
        Form {
            Section("Client ID（已内置 aMe-8VSlkrbQXpUR，通常留空即可）") {
                TextField("留空使用内置 ID", text: $clientIDDraft)
                    .autocorrectionDisabled()
                    .onChange(of: clientIDDraft) { newValue in
                        CredentialStore.set(newValue, for: "guangya.clientID")
                    }
            }
            if signedIn {
                Section {
                    Text("已登录：\(provider.displayName ?? "")")
                    Button("退出登录", role: .destructive) {
                        provider.signOut()
                        signedIn = false
                        AuthState.shared.bump()
                    }
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
                signedIn = true
                AuthState.shared.bump()
                status = "登录成功"
            } catch {
                status = "登录失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 百度：引导注册开放平台 + oob 授权码登录
struct BaiduLoginView: View {
    private let provider = ProviderRegistry.baidu
    @State private var signedIn = ProviderRegistry.baidu.isSignedIn
    @State private var appKey = CredentialStore.get("baidu.appKey") ?? ""
    @State private var secretKey = CredentialStore.get("baidu.secretKey") ?? ""
    @State private var authCode = ""
    @State private var status = ""

    var body: some View {
        Form {
            Section("开放平台应用（pan.baidu.com/union 创建应用）") {
                TextField("AppKey", text: $appKey).autocorrectionDisabled()
                    .onChange(of: appKey) { CredentialStore.set($0, for: "baidu.appKey") }
                SecureField("SecretKey", text: $secretKey).autocorrectionDisabled()
                    .onChange(of: secretKey) { CredentialStore.set($0, for: "baidu.secretKey") }
            }
            if signedIn {
                Section {
                    Text("已登录：\(provider.displayName ?? "")")
                    Button("退出登录", role: .destructive) {
                        provider.signOut()
                        signedIn = false
                        AuthState.shared.bump()
                    }
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
                signedIn = true
                AuthState.shared.bump()
                status = "登录成功"
            } catch {
                status = "登录失败：\(error.localizedDescription)"
            }
        }
    }
}

/// 夸克：粘贴网页版 Cookie（实验性）
struct QuarkLoginView: View {
    private let provider = ProviderRegistry.quark
    @State private var signedIn = ProviderRegistry.quark.isSignedIn
    @State private var cookie = ""
    @State private var testing = false
    @State private var testResult: String?

    private func runTest() {
        testing = true
        testResult = nil
        Task {
            let r = await provider.selfTest()
            await MainActor.run {
                testResult = r
                testing = false
            }
        }
    }

    var body: some View {
        Form {
            if signedIn {
                Section {
                    Text("已导入 Cookie")
                    Button("退出登录", role: .destructive) {
                        provider.signOut()
                        signedIn = false
                        AuthState.shared.bump()
                    }
                }
                NavigationLink("浏览文件 →") { FileBrowserView(kind: .quark) }

                Section("播放异常时先自检") {
                    Button(testing ? "检测中…" : "自检：列目录 + 取直链") { runTest() }
                        .disabled(testing)
                    if let testResult {
                        Text(testResult)
                            .font(.system(size: 11, design: .monospaced))
                            .textSelection(.enabled)
                    } else {
                        Text("会试列一次根目录，并给第一首歌取一次直链、探测 HTTP 状态。结果发我就能定位问题。")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                }
            } else {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("怎么拿 Cookie").font(.footnote.weight(.semibold))
                        Text("1. 手机/电脑浏览器打开 pan.quark.cn 并登录\n2. 电脑按 F12 → Network（网络）\n3. 刷新页面，点列表里任意一条 sort 请求\n4. 在 Request Headers 里找到 Cookie，整段复制粘贴到下面")
                            .font(.footnote)
                            .foregroundColor(.secondary)
                    }
                    TextEditor(text: $cookie).frame(minHeight: 140)
                        .font(.system(size: 12, design: .monospaced))
                    Button("导入并登录") {
                        let value = cookie.trimmingCharacters(in: .whitespacesAndNewlines)
                        provider.setCookie(value)
                        signedIn = !value.isEmpty
                        AuthState.shared.bump()
                    }
                }
            }
            Section {
                Text("⚠️ 夸克官方未开放 API，本功能基于社区逆向接口，可能随时失效或触发账号风控，请自行斟酌。Cookie 等同于账号密码，本机保存在 App 沙盒内，不会上传。")
                    .font(.footnote).foregroundColor(.orange)
            }
        }
        .navigationTitle("夸克网盘")
    }
}
