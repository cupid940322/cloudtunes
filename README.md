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
- **锁屏歌词**：把系统锁屏播放控件的两行文字换成「当前这句 / 歌名 — 歌手」，换句即更新；可在「我的 → 播放」里关掉
- **锁屏收藏**：锁屏 / 控制中心媒体控件上的收藏按钮（系统绘制的星形，空心 = 未收藏、实心 = 已收藏），与 App 内「我喜欢的音乐」同一份数据
- **界面**：自定义悬浮标签栏、继续播放卡片、专辑墙、模糊封面播放页（对标网易云 / Apple Music）
- **iPad 适配**：iPad 上自动切「侧栏 + 内容」分栏布局（音乐库 / 搜索 / 我喜欢的音乐 / 最近播放 / 我的），专辑墙列数随宽度自适应，播放页横屏左右分栏（左封面右歌词），主内容限宽居中；支持分屏 / Slide Over / 台前调度
- **收藏 / 最近播放 / 全库搜索**
- **跨设备同步**：用 GitHub 账号登录，刮削结果、收藏、播放记录、库列表存进自己的私有 Gist；换设备登录同一账号直接拿回来，**一首都不用重刮**

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

## 跨设备同步

「我的 → 账号与同步」里用 GitHub 账号登录即可。第一次登录时：

1. 点「打开 GitHub 生成令牌」，页面已预勾 `gist` 权限，拉到最下面点 Generate token
2. 复制 `ghp_` 开头的字符串，粘回 App 登录
3. App 自动在你账号下创建一个名为 `cloudtunes-sync` 的**私有 Gist**，之后所有同步数据都在里面

同步的内容：歌名 / 歌手 / 专辑 / 封面地址 / 时长 / 收藏 / 播放记录 / 继续播放 / 音乐库列表。
**不同步**网盘登录凭证——那是设备私有的，每台设备各自登录一次。

实现要点：

- 存储按「一个音乐库一个文件」切分（`account.json` + `library-<库ID>.json`），
  避开 Gist 单文件内容超过约 1MB 会被 API 截断的问题
- 合并策略是**实体级 LWW**：同一首歌/同一个库谁的 `updatedAt` 更新就用谁的；
  收藏 / 播放记录整体取较新的一方；删除靠墓碑（tombstone）记录，防止被另一台设备「同步复活」
- 封面只同步 URL，图片由各设备按需下载缓存，不上传二进制
- 触发时机：登录后、冷启动、回到前台（2 分钟内不重复）、刮削完成、收藏/记录变化（防抖）

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
- 网盘凭证暂存 UserDefaults（GitHub 同步令牌已用 Keychain）
- 夸克接口为社区逆向，失效需跟进更新
- 音乐库元数据存 `Documents/libraries.json`，曲目上千时首次加载略慢
- 同步令牌是 long-lived 凭证，只勾了 `gist` 权限；一旦泄露去 GitHub 吊销即可

## 安卓版（`android/`）

Kotlin + Jetpack Compose + Media3，功能对齐 iOS 端：

- 三大网盘：光鸭云盘（短信登录）/ 百度网盘（开放平台 OAuth）/ 夸克网盘（Cookie 导入，`__puus` 自动刷新）
- 音乐库扫描 + 三源刮削（网易云/QQ音乐/iTunes 打分匹配）+ LRC 歌词高亮
- 播放：ExoPlayer，夸克直链带 Cookie + Referer + 客户端 UA 三件套；失败自动切下一首；通知栏/锁屏媒体控件
- **Gist 同步与 iOS 端完全互通**：同一 GitHub Token，音乐库/收藏/播放记录/继续播放三端共享
- CI：push 到 main 触发 `android.yml`，自动出 APK 发到 Releases（tag `app-android-*`），国内可用 gh-proxy 加速下载

最低要求 Android 8.0（API 26），调试签名 APK，安装时需允许「未知来源应用」。

## 安卓 TV 版

- 独立应用 `云音 TV`（applicationId `com.gysbs.cloudtunes.tv`），**支持 Android 7.0+**
- TV 桌面（Leanback）直接显示图标；遥控器焦点导航，聚焦放大高亮
- 播放页为 TV 专用大屏布局：封面 + 歌词高亮、±10 秒快进退、播放中保持屏幕常亮
- 数据与手机/iOS 端完全互通（同一 Gist）：登录 GitHub Token 后音乐库、收藏、继续播放自动同步
- 「我的」页可登录网盘（遥控器输入不方便，建议先在手机版登录网盘和 GitHub，TV 端登录 GitHub 即可拉取全部数据）

### 软件内更新（手机版 / TV 版通用）

- 每次 CI 构建把 `run_number` 写进 `versionCode` / `versionName`（形如 `1.0.9`），APK 发布到 Releases
- App 启动时静默检查一次（24 小时节流），发现新版本弹窗；「我的 → 版本更新」可手动检查
- 三条通道，按序尝试：
  1. **光鸭云盘**（国内直连，不受网络限制）
  2. 仓库里的 `update/android-latest.json`（gh-proxy / ghproxy / ghfast / jsDelivr / raw 六个镜像）
  3. GitHub Releases API（最后兜底）
- 应用内直接下载（带进度条），下载完调系统安装器覆盖安装
- 首次安装更新时系统会要求允许「安装未知应用」，App 会自动跳到该设置页，允许后回到 App 再点「立即安装」
- TV 版同样支持；若电视盒子的系统精简掉了安装器，会提示 APK 保存路径，可用文件管理器安装

### 用光鸭云盘做更新源（不依赖 GitHub）

GitHub 在手机网络下经常连不上，把安装包放进自己的光鸭云盘就彻底绕开了这个限制：

1. 在 App「我的 → 光鸭云盘」登录（登录过一次即可，token 会刷新）
2. 从 Releases 页下载带版本号的文件：`cloudtunes-phone-1.0.16.apk` / `cloudtunes-tv-1.0.16.apk`
3. 把文件丢进光鸭云盘**根目录**，或根目录下名为 `CloudTunes` / `更新` / `update` 的文件夹
4. 回到 App 点「版本更新 → 检查更新」，就会从光鸭取包并下载安装

命名规则：`cloudtunes-phone-<版本>.apk`、`cloudtunes-tv-<版本>.apk`，版本号取最后一段数字与 `versionCode` 比较（`1.0.16` → 16）。文件名不对会被忽略，所以不会误装。

### 崩溃日志

「我的 → 崩溃日志」会记录闪退堆栈（保存在应用私有目录 `crash.log`），点「复制」即可发给开发者定位问题。
