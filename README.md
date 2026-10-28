# 云音盒 CloudTunes — iOS 云盘音乐播放器

直连光鸭云盘 / 百度网盘 / 夸克网盘，浏览云端文件夹、自动搜刮音乐文件并在线流式播放；无内嵌歌词时自动通过 LRCLIB 在线匹配歌词。

## 功能

- **多网盘登录**
  - 光鸭云盘：手机号 + 短信验证码登录（接口与 OpenList 光鸭驱动一致）
  - 百度网盘：官方开放平台 OAuth（需在 pan.baidu.com/union 创建应用）
  - 夸克网盘：网页版 Cookie 导入（实验性，官方无开放 API，有风控风险）
- **音乐搜刮**：浏览目录时自动识别 mp3 / flac / m4a / aac / wav / aiff 等格式，支持「播放本文件夹全部」
- **流式播放**：AVPlayer 直连网盘直链，后台播放
- **歌词**：优先读取云盘同名 `.lrc` 文件 → LRCLIB 在线匹配（逐行滚动）→ 手动搜索

## 环境限制说明（重要）

- 本机是 **Windows**，iOS 应用无法本地编译。构建流程为：代码推送到 GitHub → GitHub Actions（macOS runner）用 XcodeGen 生成工程并编译 → 产出**未签名 ipa** 工件。
- **未购买 Apple 开发者账号**，因此：
  - 无法上架 App Store，仅个人侧载使用；
  - 使用免费 Apple ID 签名后，App **每 7 天过期**，需重新签名安装（可用 AltStore/SideStore 自动续签）；
  - 单个 Apple ID 最多同时侧载 3 个 App。

## 构建与安装流程

1. 将本目录推送到 GitHub 仓库（如 `cupid940322/cloudtunes`），Actions 会自动构建，在 Artifacts 下载 `CloudTunes-unsigned-ipa`。
2. Windows 上下载 [Sideloadly](https://sideloadly.io)，插入 iPhone：
   - 拖入 ipa → 输入你的 Apple ID → Start → 输入手机验证码 → 等待签名安装完成。
   - 手机上：设置 → 通用 → VPN与设备管理 → 信任对应开发者证书。
3. 7 天后过期时重复步骤 2（或安装 AltStore 让手机在同 Wi-Fi 下自动续签）。

## 首次配置

### 光鸭云盘
需要网页端 Client ID：
1. 电脑浏览器打开 https://www.guangyapan.com 并登录；
2. F12 → Network → 刷新 → 找发往 `api.guangyapan.com` 的请求；
3. 复制请求头 `X-Client-Id` 的值，填入 App 的「光鸭云盘」登录页。

### 百度网盘
1. 注册/登录 [百度网盘开放平台](https://pan.baidu.com/union)，创建应用，获得 AppKey / SecretKey，回调 URI 填 `oob`；
2. 在 App「百度网盘」页填入 Key，点授权链接登录并复制授权码回填。
- ⚠️ 个人开发者账号对第三方播放（尤其大文件/音频直链）可能有限制，如遇 errno 限制需企业认证或开通相关权限。

### 夸克网盘
1. 浏览器登录 pan.quark.cn → F12 → Network → 任意请求 → 复制完整 Cookie；
2. 粘贴导入。
- ⚠️ 纯逆向接口，随时可能失效或触发账号风控，请自行斟酌。

## 技术栈

- SwiftUI + AVFoundation（AVPlayer 流式播放、AVAudioSession 后台音频）
- XcodeGen 管理工程（`project.yml`），CI 内 `xcodegen generate` 生成 xcodeproj
- 歌词：LRCLIB 公开 API（免费无 Key）+ LRC 解析器
- 各网盘 Provider 独立实现 `CloudProvider` 协议（`Services/` 目录），新增网盘只需新增一个文件

## 目录结构

```
CloudTunes/
├── project.yml                    # XcodeGen 工程定义
├── .github/workflows/build.yml    # macOS CI 云端打包 unsigned ipa
└── CloudTunes/
    ├── App/                       # 入口
    ├── Models/                    # 数据模型
    ├── Services/                  # CloudProvider 协议 + 光鸭/百度/夸克实现 + 搜刮/歌词
    ├── Player/                    # 播放管理
    └── Features/                  # 登录页 / 文件浏览 / 播放页
```

## 已知限制（后续迭代方向）

- ape / ogg / wma / opus 等格式 iOS 原生不支持，暂未收录，后续可引入 ffmpeg 组件
- 未实现锁屏播放控制（MPNowPlayingInfoCenter / MPRemoteCommandCenter）
- 凭证暂存 UserDefaults，正式版应迁移 Keychain
- 夸克接口为社区逆向，失效需跟进更新
