import Foundation
import UIKit

/// 跨设备同步：把「已刮削的音乐信息 + 收藏 + 播放记录 + 库列表 + 继续播放」
/// 存进本人在 GitHub 上的一个**私有 Gist**，另一台设备登录同一个 GitHub 账号后拉下来。
///
/// 为什么是 Gist 而不是自建数据库：
/// - 数据量很小（一首歌的元数据约 200 字节，几千首也就几百 KB）
/// - 私有 Gist 只有本人可见，等于一块免费的小云盘
/// - 不用注册新服务、不用租服务器，也不会因为试用到期把数据锁死
///
/// 冲突策略：**按实体做 LWW（last write wins）**，即同一个库/同一首歌
/// 谁的 `updatedAt` 更新就用谁的。删除靠墓碑（tombstone）记录，
/// 否则已经删掉的歌会被另一台设备"同步复活"。
@MainActor
final class SyncService: ObservableObject {

    static let shared = SyncService()

    // MARK: - 对外状态

    enum Status: Equatable {
        case idle
        case syncing(String)
        case done(tracks: Int, at: Date)
        case failed(String)

        var isRunning: Bool { if case .syncing = self { return true }; return false }
    }

    @Published private(set) var status: Status = .idle
    @Published private(set) var isSignedIn: Bool = GitHubAccount.isSignedIn
    @Published private(set) var login: String? = GitHubAccount.cachedLogin
    @Published private(set) var lastSyncAt: Date?
    @Published private(set) var lastTrackCount: Int = 0
    /// 已连接到的 Gist（用于界面显示链接）
    @Published private(set) var gistID: String?

    private let lastSyncKey = "cloudtunes.sync.lastAt"
    private let lastCountKey = "cloudtunes.sync.lastCount"
    private let gistKey = "cloudtunes.sync.gistID"

    // MARK: - 云端文件布局
    //
    // Gist 单个文件的 content 超过约 1MB 时 API 会返回 truncated，
    // 所以按「一个音乐库一个文件」切开，而不是全塞在一个 JSON 里。
    //   account.json          —— 库清单 / 收藏 / 播放记录 / 继续播放 / 墓碑
    //   library-<库ID>.json   —— 这个库的全部曲目元数据

    private static let accountFile = "account.json"
    private static func libraryFile(_ id: String) -> String {
        // Gist 文件名不允许路径分隔符，库 ID 是 UUID 本来就没问题；
        // 保险起见把斜杠和空格换掉。
        let safe = id.replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        return "library-\(safe).json"
    }

    private var deviceName: String {
        #if targetEnvironment(macCatalyst)
        return "Mac"
        #else
        return UIDevice.current.name
        #endif
    }

    private init() {
        let d = UserDefaults.standard
        if let t = d.object(forKey: lastSyncKey) as? Date { lastSyncAt = t }
        lastTrackCount = d.integer(forKey: lastCountKey)
        gistID = d.string(forKey: gistKey)
    }

    // MARK: - 登录 / 退出

    func signIn(token: String) async throws {
        let cleaned = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { throw GitHubAccount.AuthError.invalidToken }
        let identity = try await GitHubAccount.verify(cleaned)
        GitHubAccount.token = cleaned
        GitHubAccount.cachedLogin = identity.login
        login = identity.login
        isSignedIn = true
        // 登录后立刻同步一次，把本地已有的刮削结果先推上去
        await sync(reason: "登录后同步")
    }

    func signOut() {
        GitHubAccount.signOut()
        UserDefaults.standard.removeObject(forKey: gistKey)
        UserDefaults.standard.removeObject(forKey: lastSyncKey)
        UserDefaults.standard.removeObject(forKey: lastCountKey)
        isSignedIn = false
        login = nil
        gistID = nil
        lastSyncAt = nil
        lastTrackCount = 0
        status = .idle
    }

    /// 换一套云端数据（相当于换个同步账号）：清掉记住的 Gist，下次重新找
    func resetRemoteLink() {
        UserDefaults.standard.removeObject(forKey: gistKey)
        gistID = nil
    }

    // MARK: - 定时/触发同步

    private var running = false
    private var pending = false
    private var debounceTask: Task<Void, Never>?

    /// 改动后调这个：5 秒内多次改动只同步一次
    func scheduleSync(reason: String = "自动同步", delay: UInt64 = 5) {
        guard isSignedIn else { return }
        debounceTask?.cancel()
        debounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: delay * 1_000_000_000)
            guard !Task.isCancelled else { return }
            await self?.sync(reason: reason)
        }
    }

    /// 冷启动 / 回到前台时调：上次同步太近就跳过，避免每次切一下 App 就打一轮请求
    func syncIfStale(minInterval: TimeInterval = 120) async {
        guard isSignedIn else { return }
        if let lastSyncAt, Date().timeIntervalSince(lastSyncAt) < minInterval { return }
        await sync(reason: "自动同步")
    }

    func sync(reason: String = "手动同步") async {        guard isSignedIn, let token = GitHubAccount.token else { return }
        // 同步中又来一次：记下来，等当前这轮结束再补一轮，
        // 否则刮削过程中的高频触发会把请求打爆。
        if running {
            pending = true
            return
        }
        running = true
        defer { running = false }

        status = .syncing(reason)
        do {
            let count = try await performSync(token: token)
            lastTrackCount = count
            lastSyncAt = Date()
            UserDefaults.standard.set(lastSyncAt, forKey: lastSyncKey)
            UserDefaults.standard.set(count, forKey: lastCountKey)
            status = .done(tracks: count, at: Date())
        } catch {
            let msg = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            status = .failed(msg)
        }

        if pending {
            pending = false
            // 必须先释放 running 再递归：补同步发生在 defer 之前，
            // 此时 running 还是 true，递归进来只会把 pending 重新置 true 后直接返回——
            // 「补同步」静默被吞，删除/修正的那一轮就丢了
            running = false
            await sync(reason: "补同步")
        }
    }

    // MARK: - 主流程

    private func performSync(token: String) async throws -> Int {
        let gid = try await ensureGist(token: token)
        gistID = gid

        // 1. 拉云端
        let remoteFiles = try await fetchFiles(gistID: gid, token: token)
        let remoteAccount = Self.decodeAccount(remoteFiles[Self.accountFile])

        // 2. 本地快照
        let localAccount = LibraryStore.shared.syncSnapshot(deviceName: deviceName)

        // 3. account 级合并
        let merged = Self.mergeAccount(local: localAccount, remote: remoteAccount)

        // 4. 逐库合并曲目
        var libraryPayloads: [String: String] = [:]
        var mergedLibraries: [MusicLibrary] = []
        var totalTracks = 0

        for meta in merged.libraries {
            let localLib = LibraryStore.shared.library(id: meta.id)
            let remoteLib = Self.decodeLibrary(remoteFiles[Self.libraryFile(meta.id)])
            let tombstones = merged.deletedTracks[meta.id] ?? [:]

            let tracks = Self.mergeTracks(local: localLib?.tracks ?? [],
                                          remote: remoteLib?.tracks ?? [],
                                          tombstones: tombstones)
            totalTracks += tracks.count

            var lib = MusicLibrary(id: meta.id,
                                   name: meta.name,
                                   providerKindRaw: meta.providerKindRaw,
                                   folderID: meta.folderID,
                                   folderName: meta.folderName,
                                   tracks: tracks,
                                   createdAt: meta.createdAt,
                                   lastScanAt: meta.lastScanAt,
                                   includeSubfolders: meta.includeSubfolders,
                                   updatedAt: meta.updatedAt)
            // 本地没有这个库时（新设备），时间戳沿用云端的，
            // 避免它看起来比云端"更新"从而把云端的曲目覆盖掉。
            if localLib == nil { lib.updatedAt = remoteLib?.updatedAt ?? meta.updatedAt }
            mergedLibraries.append(lib)

            // 只有合并结果和云端不一样时才上传（说明本地贡献了新内容）
            let remoteTracks = remoteLib?.tracks ?? []
            if Self.needsUpload(local: remoteTracks, merged: tracks) {
                let payload = SyncLibraryFile(libraryID: meta.id,
                                              updatedAt: Date(),
                                              tracks: tracks)
                if let text = Self.encode(payload) {
                    libraryPayloads[Self.libraryFile(meta.id)] = text
                }
            }
        }

        // 5. 落到本地
        LibraryStore.shared.applySync(libraries: mergedLibraries,
                                      favorites: Set(merged.favorites),
                                      recent: merged.recent,
                                      session: merged.session,
                                      deletedLibraries: merged.deletedLibraries,
                                      deletedTracks: merged.deletedTracks)

        // 6. 上传 account.json（内容没实质变化就跳过，Gist 会留版本历史，别刷垃圾版本）
        var filesToPush = libraryPayloads
        if Self.accountNeedsUpload(remote: remoteAccount, merged: merged),
           let accountText = Self.encode(merged) {
            filesToPush[Self.accountFile] = accountText
        }

        if !filesToPush.isEmpty {
            try await patchFiles(gistID: gid, token: token, files: filesToPush)
        }

        // 7. 补齐封面：新设备只有 URL 没有本地图，后台慢慢下
        LibraryStore.shared.backfillArtwork(libraryIDs: mergedLibraries.map { $0.id })

        return totalTracks
    }

    private static func needsUpload(local: [LibraryTrack], merged: [LibraryTrack]) -> Bool {
        if local.count != merged.count { return true }
        let localMap = Dictionary(uniqueKeysWithValues: local.map { ($0.id, $0) })
        for t in merged {
            guard let l = localMap[t.id] else { return true }
            if (l.updatedAt ?? .distantPast) != (t.updatedAt ?? .distantPast) { return true }
            // 比 artworkURL 而不是 artworkFile：后者是本机缓存的文件名，
            // 每台设备都不一样，拿它比会导致每次都判定为「有变化」。
            if l.title != t.title || l.artist != t.artist || l.artworkURL != t.artworkURL { return true }
        }
        return false
    }

    /// account.json 是否真的有变化。逐字段比而不是比整个 JSON：
    /// 编码结果里含有时间戳等易变字段，直接比字符串会每次都判定为「变了」。
    private static func accountNeedsUpload(remote: SyncAccount, merged: SyncAccount) -> Bool {
        if remote.libraries.count != merged.libraries.count { return true }
        let remoteMap = Dictionary(uniqueKeysWithValues: remote.libraries.map { ($0.id, $0) })
        for m in merged.libraries {
            guard let r = remoteMap[m.id] else { return true }
            if r.name != m.name || r.folderID != m.folderID { return true }
            if r.updatedAt != m.updatedAt { return true }
        }
        if Set(remote.favorites) != Set(merged.favorites) { return true }
        if remote.recent != merged.recent { return true }
        if remote.session?.updatedAt != merged.session?.updatedAt { return true }
        if remote.deletedLibraries != merged.deletedLibraries { return true }
        if remote.deletedTracks != merged.deletedTracks { return true }
        return false
    }

    // MARK: - 合并

    static func mergeAccount(local: SyncAccount, remote: SyncAccount) -> SyncAccount {
        let remoteIsNewer = remote.updatedAt > local.updatedAt

        // 库清单：按 id 并集，同一 id 取 updatedAt 新的
        var libMap: [String: LibraryMeta] = [:]
        for m in remote.libraries { libMap[m.id] = m }
        for m in local.libraries {
            if let r = libMap[m.id] {
                if m.updatedAt >= r.updatedAt { libMap[m.id] = m }
            } else {
                libMap[m.id] = m
            }
        }
        // 墓碑合并取最新一次删除：min 会导致「一次失效就永久失效」——库被恢复后
        // updatedAt 变新，最早的删除时间永远压不过它，之后怎么删都删不掉。
        // 墓碑无条件胜出：库 id 是 UUID 永不复用（重新添加同一文件夹会得到新 id），
        // 有墓碑的库一律视为已删除。旧逻辑「删除时间晚于库 updatedAt 才算删」会被
        // 另一端的扫描/改名刷时间戳轻易击穿——这正是「删库过几秒又出现」的根因
        let mergedDeletedLibs = local.deletedLibraries.merging(remote.deletedLibraries, uniquingKeysWith: max)
        for id in mergedDeletedLibs.keys {
            libMap.removeValue(forKey: id)
        }

        // 收藏 / 播放记录：整体取较新的一方。
        // 单人多设备场景下冲突概率很低，整体覆盖比逐条合并更好预测；
        // 逐条合并反而会让「取消收藏」永远同步不过去。
        // 但「一边为空」时不按时间戳判：新设备（收藏为空）绝不能把云端收藏抹掉。
        let favorites: [String]
        if local.favorites.isEmpty, !remote.favorites.isEmpty {
            favorites = remote.favorites
        } else if remote.favorites.isEmpty, !local.favorites.isEmpty {
            favorites = local.favorites
        } else {
            favorites = remoteIsNewer ? remote.favorites : local.favorites
        }
        let recent: [String]
        if local.recent.isEmpty, !remote.recent.isEmpty {
            recent = remote.recent
        } else if remote.recent.isEmpty, !local.recent.isEmpty {
            recent = local.recent
        } else {
            recent = remoteIsNewer ? remote.recent : local.recent
        }

        // 继续播放：整体取 updatedAt 新的（播放进度就在这里面，不必单独存一张表）
        let session: PlaybackSession?
        switch (local.session, remote.session) {
        case let (l?, r?): session = (l.updatedAt >= r.updatedAt) ? l : r
        case let (l?, nil): session = l
        case let (nil, r?): session = r
        default: session = nil
        }

        // updatedAt 取两边的最大值，而不是「现在」。
        // 否则每次同步都会把时间戳刷新成当前时间，云端看起来永远是最新的，
        // 另一台设备就会一直用远端覆盖本地，而且每次都产生一次无谓的写入。
        let mergedUpdatedAt = max(local.updatedAt, remote.updatedAt)

        return SyncAccount(schemaVersion: 1,
                           updatedAt: mergedUpdatedAt,
                           deviceName: local.deviceName,
                           libraries: Array(libMap.values).sorted { $0.createdAt < $1.createdAt },
                           favorites: favorites,
                           recent: recent,
                           session: session,
                           deletedLibraries: mergedDeletedLibs,
                           deletedTracks: mergeTombstoneMaps(local.deletedTracks, remote.deletedTracks))
    }

    private static func mergeTombstoneMaps(_ a: [String: [String: Date]],
                                           _ b: [String: [String: Date]]) -> [String: [String: Date]] {
        var out = a
        for (libID, marks) in b {
            if var existing = out[libID] {
                for (tid, at) in marks {
                    existing[tid] = max(existing[tid] ?? at, at)
                }
                out[libID] = existing
            } else {
                out[libID] = marks
            }
        }
        return out
    }

    static func mergeTracks(local: [LibraryTrack],
                            remote: [LibraryTrack],
                            tombstones: [String: Date]) -> [LibraryTrack] {
        var map: [String: LibraryTrack] = [:]
        for t in remote { map[t.id] = t }
        for t in local {
            if let r = map[t.id] {
                map[t.id] = mergeTrack(t, r)
            } else {
                map[t.id] = t
            }
        }
        for (id, at) in tombstones {
            // 曲目 id 会复用（删掉后重新扫描同一文件会生成同一 id），保留
            // 「重新添加的时间新于删除时间则复活」的语义；墓碑本身取 max 合并
            if let t = map[id], at > (t.updatedAt ?? .distantPast) {
                map.removeValue(forKey: id)
            }
        }
        return map.values.sorted {
            ($0.addedAt ?? .distantPast) < ($1.addedAt ?? .distantPast)
        }
    }

    /// 单条曲目合并：手动修过的优先，其次才比 updatedAt。
    /// 只比时间戳的话，另一端任何批量操作（重扫/重新识别）都会把整库时间刷成
    /// 「现在」，把这一端手工纠正的结果合法地压掉——用户手动改过的信息必须保住
    private static func mergeTrack(_ local: LibraryTrack, _ remote: LibraryTrack) -> LibraryTrack {
        let lManual = local.metaSource == "manual"
        let rManual = remote.metaSource == "manual"
        if lManual != rManual { return lManual ? local : remote }
        return (local.updatedAt ?? .distantPast) >= (remote.updatedAt ?? .distantPast) ? local : remote
    }

    // MARK: - 编解码

    static func encoder() -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.withoutEscapingSlashes]
        return e
    }

    static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }

    private static func encode<T: Encodable>(_ value: T) -> String? {
        guard let data = try? encoder().encode(value) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    private static func decodeAccount(_ text: String?) -> SyncAccount {
        guard let text, let data = text.data(using: .utf8),
              let v = try? decoder().decode(SyncAccount.self, from: data) else { return SyncAccount() }
        return v
    }

    private static func decodeLibrary(_ text: String?) -> SyncLibraryFile? {
        guard let text, let data = text.data(using: .utf8),
              let v = try? decoder().decode(SyncLibraryFile.self, from: data) else { return nil }
        return v
    }

    // MARK: - GitHub Gist

    private struct GistFile: Decodable {
        let filename: String
        let content: String?
        let truncated: Bool?
        let raw_url: String?
    }

    private struct GistPayload: Decodable {
        let id: String
        let description: String?
        let files: [String: GistFile]
    }

    private static let syncDescription = "cloudtunes-sync"

    private func request(_ url: URL, token: String, method: String = "GET", body: Data? = nil) -> URLRequest {
        var req = URLRequest(url: url)
        req.httpMethod = method
        req.timeoutInterval = 30
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("2022-11-28", forHTTPHeaderField: "X-GitHub-Api-Version")
        if let body {
            req.httpBody = body
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        return req
    }

    private func send(_ req: URLRequest) async throws -> (Data, HTTPURLResponse) {
        let (data, response): (Data, URLResponse)
        do {
            (data, response) = try await URLSession.shared.data(for: req)
        } catch {
            throw SyncError.network(error.localizedDescription)
        }
        guard let http = response as? HTTPURLResponse else { throw SyncError.network("响应异常") }
        if http.statusCode == 401 { throw SyncError.tokenExpired }
        if http.statusCode == 403 {
            throw SyncError.message("GitHub 拒绝了请求（403），可能是令牌权限不足或请求过于频繁")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw SyncError.message("GitHub 返回 HTTP \(http.statusCode)")
        }
        return (data, http)
    }

    /// 找到（或创建）用来存同步数据的私有 Gist。
    /// 认领方式是 description 标记，这样用户自己建的其它 Gist 不会被误写。
    private func ensureGist(token: String) async throws -> String {
        if let cached = gistID, !cached.isEmpty {
            // 验证它还在（用户可能手动删了）
            if let (data, _) = try? await send(request(
                URL(string: "https://api.github.com/gists/\(cached)")!, token: token)),
               (try? JSONDecoder().decode(GistPayload.self, from: data)) != nil {
                return cached
            }
            resetRemoteLink()
        }

        var page = 1
        while page <= 3 {
            let url = URL(string: "https://api.github.com/gists?per_page=100&page=\(page)")!
            let (data, _) = try await send(request(url, token: token))
            guard let list = try? JSONDecoder().decode([GistPayload].self, from: data) else { break }
            if let hit = list.first(where: { $0.description == Self.syncDescription }) {
                UserDefaults.standard.set(hit.id, forKey: gistKey)
                return hit.id
            }
            if list.count < 100 { break }
            page += 1
        }

        // 没有就建一个私有的
        let body: [String: Any] = [
            "description": Self.syncDescription,
            "public": false,
            "files": [Self.accountFile: ["content": "{}"]],
        ]
        let data = try JSONSerialization.data(withJSONObject: body)
        let (resp, _) = try await send(request(URL(string: "https://api.github.com/gists")!,
                                               token: token, method: "POST", body: data))
        guard let obj = try? JSONSerialization.jsonObject(with: resp) as? [String: Any],
              let id = obj["id"] as? String else {
            throw SyncError.message("创建同步空间失败")
        }
        UserDefaults.standard.set(id, forKey: gistKey)
        return id
    }

    private func fetchFiles(gistID: String, token: String) async throws -> [String: String] {
        let url = URL(string: "https://api.github.com/gists/\(gistID)")!
        let (data, _) = try await send(request(url, token: token))
        guard let payload = try? JSONDecoder().decode(GistPayload.self, from: data) else {
            return [:]
        }
        var out: [String: String] = [:]
        for (name, file) in payload.files {
            if let content = file.content, file.truncated != true {
                out[name] = content
                continue
            }
            // 超过 1MB 的内容 API 会给 truncated，得单独走 raw_url 拉全量
            if let raw = file.raw_url, let rawURL = URL(string: raw) {
                if let (d, _) = try? await send(request(rawURL, token: token)),
                   let text = String(data: d, encoding: .utf8) {
                    out[name] = text
                }
            }
        }
        return out
    }

    private func patchFiles(gistID: String, token: String, files: [String: String]) async throws {
        var payload: [String: Any] = [:]
        for (name, content) in files {
            payload[name] = ["content": content]
        }
        let body = try JSONSerialization.data(withJSONObject: ["files": payload])
        let url = URL(string: "https://api.github.com/gists/\(gistID)")!
        _ = try await send(request(url, token: token, method: "PATCH", body: body))
    }

    // MARK: - 错误

    enum SyncError: LocalizedError {
        case network(String)
        case tokenExpired
        case message(String)

        var errorDescription: String? {
            switch self {
            case .network(let m): return "网络错误：\(m)"
            case .tokenExpired: return "令牌已失效，请到账号页重新登录"
            case .message(let m): return m
            }
        }
    }
}

// MARK: - 云端数据结构

struct SyncAccount: Codable {
    var schemaVersion: Int = 1
    var updatedAt: Date = Date()
    var deviceName: String = ""
    var libraries: [LibraryMeta] = []
    var favorites: [String] = []
    var recent: [String] = []
    /// 继续播放（队列 + 位置 + 时间戳），整体取较新的一份
    var session: PlaybackSession? = nil
    /// 库删除墓碑：库ID → 删除时间
    var deletedLibraries: [String: Date] = [:]
    /// 曲目删除墓碑：库ID → [曲目ID: 删除时间]
    var deletedTracks: [String: [String: Date]] = [:]
}

/// 库的轻量描述（不含曲目，曲目单独存一个文件）
struct LibraryMeta: Codable {
    var id: String
    var name: String
    var providerKindRaw: String
    var folderID: String
    var folderName: String
    var includeSubfolders: Bool
    var createdAt: Date
    var lastScanAt: Date?
    var updatedAt: Date
}

struct SyncLibraryFile: Codable {
    var libraryID: String
    var updatedAt: Date
    var tracks: [LibraryTrack]
}
