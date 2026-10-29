# 汤圆云音盒 CloudTunes — iOS 云盘音乐播放器

直连光鸭云盘 / 百度网盘 / 夸克网盘，选一个文件夹就自动递归扫描、刮削成音乐库，支持流式播放、锁屏控制、歌词滚动。

## 功能

- **多网盘登录**
  - 光鸭云盘：手机号 + 短信验证码登录（接口与 OpenList 光鸭驱动一致）
  - 百度网盘：官方开放平台 OAuth（需在 pan.baidu.com/union 创建应用）
  - 夸克网盘：网页版 Cookie 导入（实验性，官方无开放 API，有风控风险）
- **音乐库**：任意层级文件夹都能加进来，可选「包含子文件夹」递归扫描；自动整理成 歌曲 / 专辑 / 艺术家 三种视图
- **刮削（重点）**
  - 文件名清洗：序号前缀、`[FLAC]`/`(320kbps)`/`[mqms2]` 等音质来源标记、多种分隔符
  - 元数据优先级：内嵌标签 → 网易云音乐 → QQ 音乐 → iTunes（封面兜底）
  - **相似度校验**：搜索结果逐条打分，标题/歌手对不上就丢弃，宁可没封面也不贴错封面
  - 倒序文件名（`歌名-歌手`）自动反向匹配纠正
  - 低置信度的歌曲在列表里标「待确认」，可手动编辑或重新匹配
- **播放**：AVPlayer 流式播放、后台/锁屏控制、随机播放、单曲/列表循环、断点续播队列
- **歌词**：云盘同名 `.lrc` → 网易云 → LRCLIB，逐行滚动高亮，可手动换源
- **界面**：自定义悬浮标签栏、继续播放卡片、专辑墙、模糊封面播放页（对标网易云 / Apple Music）
- **收藏 / 最近播放 / 全库搜索**

## 环境限制说明（重要）

- 本机是 **Windows**，iOS 应用无法本地编译。构建流程为：代码推送到 GitHub → GitHub Actions（macOS runner）用 XcodeGen 生成工程并编译 → 产出**未签名 ipa**。
- **未购买 Apple 开发者账号**，因此：
  - 无法上架 App Store，仅个人侧载使用；
  - 使用免费 Apple ID 签名后，App **每 7 天过期**，需重新签名安装（可用 AltStore/SideStore 自动续签）；
  - 单个 Apple ID 最多同时侧载 3 个 App。

## 构建与安装流程

1. 推送到 GitHub 仓库（`cupid940322/cloudtunes`），Actions 自动构建，成功后把 ipa 发布到 Release `app-latest`。
2. Windows 上下载 [Sideloadly](https://sideloadly.io)，插入 iPhone：
   - 拖入 ipa → 输入 Apple ID → Start → 输入手机验证码 → 等待签名安装。
   - 手机上：设置 → 通用 → VPN与设备管理 → 信任开发者证书。
3. 7 天后过期时重复步骤 2。

## 首次配置

### 光鸭云盘
Client ID 已内置（`aMe-8VSlkrbQXpUR`，网页端公共客户端标识），**留空即可直接登录**。
如日后接口调整导致登录失败：网页版 F12 → Network → 任意 `api.guangyapan.com` 请求 → 请求头 `X-Client-Id`。

### 百度网盘
1. 注册/登录 [百度网盘开放平台](https://pan.baidu.com/union)，创建应用，获得 AppKey / SecretKey，回调 URI 填 `oob`；
2. 在 App「我的 → 百度网盘」填入 Key，点授权链接登录并复制授权码回填。
- ⚠️ 个人开发者账号对第三方播放（尤其大文件/音频直链）可能有限制。

### 夸克网盘
1. 浏览器登录 pan.quark.cn → F12 → Network → 任意请求 → 复制完整 Cookie；
2. 粘贴导入。
- ⚠️ 纯逆向接口，随时可能失效或触发账号风控。

## 技术栈

- SwiftUI + AVFoundation（AVPlayer 流式播放、AVAudioSession 后台音频、MPRemoteCommandCenter 锁屏控制）
- XcodeGen 管理工程（`project.yml`），CI 内 `xcodegen generate` 生成 xcodeproj
- 刮削：AVAsset 内嵌标签 + 网易云 / QQ 音乐 / iTunes 公开接口 + 自研相似度打分（`TextMatch`）
- 各网盘 Provider 独立实现 `CloudProvider` 协议，新增网盘只需新增一个文件

## 目录结构

```
CloudTunes/
├── project.yml                    # XcodeGen 工程定义
├── .github/workflows/build.yml    # macOS CI 云端打包 unsigned ipa
└── CloudTunes/
    ├── App/                       # 入口 + 自定义标签栏
    ├── Models/                    # 数据模型（Track / MusicLibrary / LibraryTrack）
    ├── Services/                  # 网盘 Provider、音乐库扫描、刮削、搜索、歌词
    ├── Player/                    # 播放管理（队列 / 随机循环 / 锁屏）
    ├── UI/                        # Theme 设计系统 + 通用组件
    └── Features/                  # 首页 / 库详情 / 搜索 / 我的 / 播放页 / 文件浏览
```

## 已知限制

- ape / ogg / wma / opus 等格式 iOS 原生不支持，暂未收录
- 凭证暂存 UserDefaults，正式版应迁移 Keychain
- 夸克接口为社区逆向，失效需跟进更新
- 音乐库元数据存 `Documents/libraries.json`，曲目上千时首次加载略慢
