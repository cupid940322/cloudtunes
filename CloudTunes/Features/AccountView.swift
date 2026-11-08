import SwiftUI
import UIKit

/// 账号与跨设备同步。
///
/// 这里的「账号」就是你的 GitHub 账号：没有注册、没有密码、没有服务器。
/// 刮削好的音乐信息存在你自己 GitHub 上的一个私有 Gist 里，
/// 另一台设备登录同一个账号就自动拉下来，一首都不用重刮。
struct AccountView: View {
    @ObservedObject private var sync = SyncService.shared
    @Environment(\.openURL) private var openURL

    @State private var token = ""
    @State private var busy = false
    @State private var error: String?
    @State private var showTokenField = false
    @State private var confirmSignOut = false

    private let tokenURL = URL(string: "https://github.com/settings/tokens/new?scopes=gist&description=CloudTunes")!

    var body: some View {
        ScrollView {
            VStack(spacing: 18) {
                headerCard
                if sync.isSignedIn {
                    signedInSection
                } else {
                    signInSection
                }
                explainSection
            }
            .padding(.horizontal, Theme.pagePadding)
            .padding(.top, 8)
            .padding(.bottom, 40)
        }
        .background(Theme.background)
        .scrollIndicators(.hidden)
        .navigationTitle("账号与同步")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog("退出登录？", isPresented: $confirmSignOut) {
            Button("退出", role: .destructive) { sync.signOut() }
            Button("取消", role: .cancel) {}
        } message: {
            Text("只是断开同步。本机已刮削的音乐信息不会丢失。")
        }
    }

    // MARK: - 顶部状态

    private var headerCard: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(sync.isSignedIn ? Theme.accentGradient : LinearGradient(
                    colors: [Color.gray.opacity(0.35), Color.gray.opacity(0.22)],
                    startPoint: .topLeading, endPoint: .bottomTrailing))
                    .frame(width: 64, height: 64)
                if sync.isSignedIn {
                    Text(initial)
                        .font(.system(size: 26, weight: .bold))
                        .foregroundStyle(.white)
                } else {
                    Image(systemName: "person.crop.circle")
                        .font(.system(size: 28, weight: .medium))
                        .foregroundStyle(.white)
                }
            }
            .shadow(color: Theme.accent.opacity(sync.isSignedIn ? 0.28 : 0), radius: 12, y: 5)

            Text(sync.isSignedIn ? "@\(sync.login ?? "GitHub")" : "未登录")
                .font(.headline)

            Text(sync.isSignedIn
                 ? "刮削结果存在你自己的私有 Gist 里"
                 : "登录后，换设备不用重新刮削")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 22)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
    }

    private var initial: String {
        let name = sync.login ?? "G"
        return String(name.prefix(1)).uppercased()
    }

    // MARK: - 已登录

    private var signedInSection: some View {
        VStack(spacing: 14) {
            VStack(spacing: 0) {
                infoRow("上次同步", sync.lastSyncAt.map(Self.relative) ?? "还没同步过")
                Divider().padding(.leading, 14)
                infoRow("云端曲目", sync.lastTrackCount > 0 ? "\(sync.lastTrackCount) 首" : "—")
                Divider().padding(.leading, 14)
                infoRow("本机音乐库", "\(LibraryStore.shared.libraries.count) 个")
                Divider().padding(.leading, 14)
                statusRow
            }
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

            Button {
                Task { await sync.sync(reason: "手动同步") }
            } label: {
                HStack(spacing: 8) {
                    if sync.status.isRunning {
                        ProgressView().tint(.white).scaleEffect(0.85)
                    } else {
                        Image(systemName: "arrow.triangle.2.circlepath")
                    }
                    Text(sync.status.isRunning ? "同步中…" : "立即同步")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(sync.status.isRunning)

            Button(role: .destructive) {
                confirmSignOut = true
            } label: {
                Text("退出登录")
                    .font(.subheadline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 12)
                    .background(Color.red.opacity(0.10), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    .foregroundStyle(.red)
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Theme.accent)
                .frame(width: 20)
            Text("同步状态").font(.subheadline)
            Spacer()
            Group {
                switch sync.status {
                case .idle:
                    Text("待命").foregroundStyle(.secondary)
                case .syncing(let reason):
                    Text(reason).foregroundStyle(.secondary)
                case .done(let n, _):
                    Text("已同步 \(n) 首").foregroundStyle(.green)
                case .failed(let msg):
                    Text(msg).foregroundStyle(.red).lineLimit(2)
                }
            }
            .font(.caption)
            .multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func infoRow(_ title: String, _ value: String) -> some View {
        HStack {
            Text(title).font(.subheadline)
            Spacer()
            Text(value).font(.subheadline).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    // MARK: - 未登录

    private var signInSection: some View {
        VStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 10) {
                stepText("1", "点下面的按钮，去 GitHub 生成一个令牌")
                stepText("2", "页面里的 gist 权限已经帮你勾好了，直接拉到最下面点 Generate token")
                stepText("3", "复制那串 ghp_ 开头的字符，回来粘贴到这里")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))

            Button {
                openURL(tokenURL)
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "safari")
                    Text("打开 GitHub 生成令牌")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(Theme.accentGradient, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)

            if showTokenField {
                tokenField
            } else {
                Button {
                    withAnimation { showTokenField = true }
                } label: {
                    Text("我已经有令牌了")
                        .font(.subheadline)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            if let error {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 4)
            }
        }
    }

    private var tokenField: some View {
        VStack(spacing: 10) {
            HStack(spacing: 8) {
                SecureField("粘贴 ghp_ 开头的令牌", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.subheadline.monospaced())
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))

                Button {
                    token = UIPasteboard.general.string ?? token
                } label: {
                    Image(systemName: "doc.on.clipboard")
                        .font(.system(size: 15, weight: .medium))
                        .padding(11)
                        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                        .foregroundStyle(Theme.accent)
                }
                .buttonStyle(.plain)
            }

            Button {
                Task { await doSignIn() }
            } label: {
                HStack(spacing: 8) {
                    if busy { ProgressView().tint(.white).scaleEffect(0.85) }
                    Text(busy ? "正在登录…" : "登录并开始同步")
                }
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .background(token.trimmingCharacters(in: .whitespaces).isEmpty
                            ? AnyShapeStyle(Color.gray.opacity(0.3))
                            : AnyShapeStyle(Theme.accentGradient),
                            in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            .disabled(busy || token.trimmingCharacters(in: .whitespaces).isEmpty)
        }
    }

    private func stepText(_ index: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Text(index)
                .font(.caption2.weight(.bold))
                .foregroundStyle(.white)
                .frame(width: 17, height: 17)
                .background(Theme.accent, in: Circle())
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 说明

    private var explainSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("同步了什么")
                .font(.title3.weight(.bold))
                .padding(.horizontal, 2)
            VStack(alignment: .leading, spacing: 7) {
                bullet("歌名、歌手、专辑、封面、时长——换设备不用再刮一遍")
                bullet("收藏、播放记录、继续播放的位置")
                bullet("音乐库列表（网盘登录状态不同步，那属于设备私有，需要各设备自己登录）")
                bullet("数据只存在你 GitHub 上的私有 Gist，别人看不到")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        }
    }

    private func bullet(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Circle().fill(Theme.accent.opacity(0.5)).frame(width: 5, height: 5).padding(.top, 6)
            Text(text)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }

    // MARK: - 动作

    private func doSignIn() async {
        busy = true
        error = nil
        defer { busy = false }
        do {
            try await sync.signIn(token: token)
            token = ""
            showTokenField = false
        } catch {
            self.error = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    static func relative(_ date: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.unitsStyle = .short
        return f.localizedString(for: date, relativeTo: Date())
    }
}
