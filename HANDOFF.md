# 红果鉴 v0.3 交接文档

> 更新时间：2026-10-26 ｜ 版本 `0.3.0+89` ｜ 分支 `main`
> 工作区包含未提交的「站源全量迁移 + 扩展格式简化」改动。

---

## 1. 项目定位（先读这段）

本项目是**基于原全站源版本（真果鉴）的全新重写**，不承诺兼容旧版本数据。v0.3 完成了从「单体 Flutter + Go 全内置站源」到「分层 Flutter + 站源插件化」的架构换代。

**当前状态**：10 个站源已全部具备 JS 扩展实现；只有红果保留 Go 内置（设备注册与请求签名不可脚本化）。扩展改为**单文件 JS + 文件头元数据**，不再使用 zip/manifest.json/签名包。

---

## 2. 当前验证状态

| 维度 | 状态 |
| --- | --- |
| `go test -race ./...` | ✅ 全绿（core ~7s / ext ~3s） |
| `dart analyze --fatal-infos lib test` | ✅ 零问题 |
| `flutter test --dart-define=DISABLE_REMOTE_IMAGES=true` | ✅ 71 个测试全绿 |
| 扩展校验 `python3 tools/build.py --check` | ✅ 10 个扩展全部通过 |
| `gofmt -l native` | ✅ 干净 |
| macOS `scripts/build_macos.py` | ✅ universal app 构建并启动，首页/韩小圈目录/分集/HLS 播放通过 |
| Linux `scripts/build_linux.py` | ✅ x64 工程/脚本/CI 已接入；arm64 待 FFmpegKit 上游支持；待 Linux 实机验证 |
| NativeChannel FFI 响应 | ✅ 修复 worker 回传 record 被父 isolate 丢弃导致 initialize 永久等待 |
| Riverpod 启动容器 | ✅ 启动依赖一次性注入，移除非法的 updateOverrides 新增 override |

---

## 3. 架构地图

### 3.1 前端分层（`lib/`）

```
lib/
├── app/            bootstrap(main.dart)、router、theme、layout、orientation、底部导航
├── core/           models、core_bridge(FFI)、local_store(存储)、providers(Riverpod)、
│                   responsive/window_type、catalog_*、follow_*、
│                   video_enhancement_preferences 等
├── data/           2026-10-26 新增的中间层，用于切断 features/widgets -> core 的反向依赖
│   └── media/      background_downloads、download_collections、media_exports、
│                   media_library、media_merge、media_merge_queue、media_pipeline、
│                   cover_decoder（原在 features/downloads 与 widgets）
├── features/       home / player / downloads / lan / detail / settings / sources
└── widgets/        共享组件、键盘焦点、VIP 图标（封面解码已迁至 data/media）
```

依赖方向（单向，不得反向）：`app → features → {data, core, widgets} → core`。

**关键约定**

- 依赖注入：路由创建的屏幕通过 `Consumer` 从 provider 读取；老屏幕仍保留显式参数传入。
- 状态管理：`storeProvider` 是 `ChangeNotifierProvider<LocalStore>` 桥接，新代码建议 `ref.watch`。
- 根组件只 watch `themeModeProvider`，其余 store 变更不再触发全树重建。
- 断点：`windowTypeOf(width)` → compact(<600) / medium(<840) / expanded；不要写裸 `maxWidth >= 840`。

### 3.2 原生核心（`native/`）

```
native/
├── core/    app_runtime(分派中心)、provider_registry(站源注册表)、
│            provider_hongguo*(唯一 Go 内置源)、app_downloads、app_catalog_*、
│            network_*、app_lan、extension_*（安装表与扩展 provider）
├── ext/     manifest(脚本头解析/索引)、goja_runtime(宿主 API)、htmlapi、
│            host(契约)、install(已装记录/索引)
└── bridge/  C ABI（仅 DuanjuRequest / DuanjuFree 两个符号）
```

### 3.3 FFI 通道

`lib/core/core_bridge.dart` 的 `NativeChannel` 是**常驻工作 isolate**：`jsonEncode/Decode` 与 FFI 调用全部在 worker 中，worker 崩溃自动重建。超时表 `_nativeActionTimeouts` 必须**长于** Go 侧 `nativeDispatch` 的对应值。

### 3.4 站源双轨制

```go
type sourceProvider interface {
    BaseURL() string
    ValidCategory(string) bool
    SupportsOnlineSearch() bool
    Categories(ctx, force) ([]nativeCategory, error)
    CatalogPage(ctx, page, category, query) ([]Drama, bool, error)
    Detail(ctx, id) ([]Chapter, error)
}
// 可选能力
type playbackResolver interface{ ResolveMedia(ctx, task) (providerMedia, error) }
type coverResolver   interface{ CoverAddress(ctx, drama, id) (string, error) }
type rankingProvider interface{ RankingBoards(); RankingPage(...) }
```

- **内置源**：仅红果，`provider_registry.go` 注册。
- **扩展源**：`extensionProvider` 动态注册，实现同一接口。
- `nativeSourceAvailable` 只对红果恒放行，其余站源查扩展安装表；未安装的源不会被授权，也不会出现在 Flutter 站源列表。
- `providerRegistry` 保留 `builtins` 副本；扩展卸载时若存在同名内置实现会回退（当前只有红果）。

---

## 4. 站源插件化

### 4.1 扩展格式

扩展是 `extensions-repo/extensions/<id>.js` 单文件，元数据写在文件头：

```js
// ==HongguoExtension==
// @id hanxiaoquan
// @name 韩小圈
// @version 1.0.0
// @apiLevel 1
// @restricted false
// @description 韩剧 · 韩国电影 · 综艺动漫
// @onlineSearch true
// @pagedSearch true
// ==/HongguoExtension==
```

可选字段：`group` / `groupName` / `entryName`（黄果系分组）、`suggestions`、`minApp`。

### 4.2 安装与分发

- **随包手动安装**：`lib/features/sources/sources_screen.dart` 读取 `extensions-repo/index.json`，用户点击安装时从 `extensions-repo/extensions/<id>.js`（pubspec asset）读取脚本，经 `installExtension(..., code: ...)` 写入 Go 数据目录；应用启动时不自动安装任何扩展。
- **官方索引**：`extensions-repo/tools/build.py` 校验脚本并生成 `index.json`（含下载地址与 SHA-256）；应用从 `extensionIndexURL` 拉取，安装时校验摘要。
- **本地/内置路径**：`nativeInput.ExtensionCode` 直接接收脚本内容；`ExtensionURL` 与 `ExtensionCode` 二选一。
- **不再签名**：旧 zip + ed25519 公钥链路已删除。信任模型为官方仓库 HTTPS + SHA-256，请只安装可信来源的扩展。
- **官网仓库**：`extensions-repo/` 需推为独立 GitHub 仓库；`extensionIndexURL` 仍是占位地址，正式发布前替换为真实地址。

### 4.3 已迁移（10 源）

| 扩展源 | 文件 | 覆盖 |
| --- | --- | --- |
| 韩小圈 | `extensions/hanxiaoquan.js` | 目录/搜索/详情/播放 |
| 鬼片 | `extensions/guipian.js` | 目录/搜索(RSS)/详情/播放 |
| 青空 | `extensions/sorani.js` | 目录/详情/播放（纯 JSON） |
| 剧果 | `extensions/huangju.js` | 分类/目录/详情/播放（CloudFront 凭证） |
| 野果 | `extensions/yeguo.js` | 分类/目录/详情/播放（配置发现+签名+AES） |
| 帝果 | `extensions/dsd.js` | 分类聚合/搜索/详情/播放（vplayer） |
| 黄豆 | `extensions/huangdou.js` | 四层加密协议 + HLS 密钥 |
| 黄果视频 | `extensions/huangguo-video.js` | 卡片目录/详情/播放 |
| 黄果 AI | `extensions/huangguoai.js` | JSON 目录/榜单/详情/播放 |
| 黄果旧版 | `extensions/cloudfront.js` | 加密 API/详情/播放 |

parity 测试在 `native/core/extension_parity_test.go`，用 HTTP fixture 覆盖目录/详情/播放解析；Go provider 已删除，测试只验证 JS 实现与预期字段。

### 4.4 扩展宿主 API（`native/ext/goja_runtime.go`）

| 命名空间 | 能力 |
| --- | --- |
| `hg.fetch` | 走应用网络栈（TLS 指纹、限流、DNS、代理） |
| `hg.fetchAll` | 并行请求 ≤32 个，支持部分失败 |
| `hg.html` | parse/findFirst/findAll/attr/text/inner/html |
| `hg.url` | parse / encodeQuery（goja 无 WHATWG URL） |
| `hg.crypto` | md5/sha256/sha3、HMAC、AES-CBC、base64/hex、gzip、随机字节、二进制安全接口 |
| `hg.storage` | 每源 KV，≤1 MiB |
| `hg.log` | 诊断日志 |

**契约要点**：`source.catalog` 返回 `{items, hasMore}`；`source.detail` 返回 `{drama, chapters}`；`source.resolve` 返回 `{url, referer?, quality?, hlsKey?, credentials?}`；`rankingBoards/rankings` 为可选榜单契约。章节 ID 的源前缀由宿主强制覆写。

### 4.5 宿主工具库 `hgkit`（`native/ext/kit.js`）

每个扩展运行前注入 `globalThis.hgkit`，把通用机制沉到宿主：

- `hgkit.defineSource`：补默认 `validCategory`（基于 `categories`）与 `resolve`（直接媒体地址），并挂载 helper。
- `source.getText/getJSON`：宿主网络栈、自动 base/Referer、状态码校验。
- `source.clean/text/pick/first/int/tags/url/mediaURL/isMediaURL/cover/meta`：清洗、字段与 URL/DOM 归一。
- `source.page/chapters/drama`：统一分页、分集去重排序、剧集字段映射。
- `source.base(ctx)`：ctx.host > `hg.storage.baseURL` > 可选 fallback（如黄豆 `host`）> 清单站点。
- 不再依赖方法里的 `this`：kit 用闭包捕获 source，宿主按方法语义传 `this`。
- `hgkit.cloudFrontCredentials`：解析 CloudFront 签名 Cookie（同时修正了旧实现 `protocol + '//'` 缺少冒号的 origin 问题）。

全部 10 个 JS 扩展均已迁移到 `hgkit.defineSource`：

| 扩展 | 迁移前 | 迁移后 |
| --- | --- | --- |
| 青空 | 316 行 | 199 行 |
| 韩小圈 | 298 行 | 228 行 |
| 鬼片 | 330 行 | 262 行 |
| 剧果 | 388 行 | 350 行 |
| 黄果视频 | 467 行 | 406 行 |
| 黄果 AI | 605 行 | 537 行 |
| 帝果 | 898 行 | 847 行 |
| 黄豆 | 588 行 | 557 行 |
| 黄果旧版 | 739 行 | 698 行 |
| 野果 | 633 行 | 576 行 |

合计 5262 → 4660 行（不含 410 行共享 kit）。加密、鉴权和 aaencode 等站点协议仍保留在扩展内。模板：`extensions-repo/tools/template.js`。

---

## 5. 发布前置条件（**发布前必须处理**）

1. **官方扩展仓库**：将 `extensions-repo/` 推为独立 GitHub 仓库，用 `build.py --base-url <真实地址>` 生成并提交 `index.json`，再替换 `native/core/extension_store.go` 的 `extensionIndexURL`。
2. ~~**CI 检查不阻塞**~~ **已于 2026-10-26 修复**：`checks` job 已移除全部 `continue-on-error`（原目标 7 处，其中 TG 推送 1 处保留为非阻塞——发布已完成，通知失败不应回滚 Release）；同时修复了 `dart analyze` / `go test` 两段重复 YAML 键。五个平台 job 由 `needs: prepare` 改为 `needs: [checks, prepare]`，analysis 不再先白烧五平台产物再失败。`checks` 超时由 20 分钟放宽到 30 分钟，避免冷缓存编译慢被误判成代码缺陷。
3. **真机验证手动安装**：Android / Windows / macOS / Linux 各跑一次全新安装，确认首启只有红果，随包扩展需手动安装，受限源默认关闭。
4. **更新扩展验证**：安装/更新/卸载、离线打开站源管理页各验证一次。
5. **macOS 公证**：当前构建为 ad-hoc 签名，正式分发需 Developer ID 签名与公证，否则用户首次打开需右键「打开」。

---

## 6. 已知技术债

| 债务 | 位置 | 说明 |
| --- | --- | --- |
| `player_screen.dart` 1680 行 | `lib/features/player/` | 布局已抽出（该目录已有 21 个文件）；但 `_PlayerScreenState` 仍是单类 State，面板拆分需先抽 `PlayerController` |
| `discovery_screen.dart` 901 行 | `lib/features/home/` | 已由原 `home_screen.dart` 更名并瘦身；导航壳与内容区仍未彻底分离 |
| ~~路由未用 StatefulShellRoute~~ | `lib/app/router.dart` | **已解决**：`router.dart:55` 现为 `StatefulShellRoute.indexedStack`，三个分支各自保留状态；本行待下次清理时删除 |
| Riverpod 只作 DI、未作状态管理 | `lib/core/providers.dart` | 全 app 仅 6 个 provider 且全部集中在此文件，领域级 provider 为 0；真实状态在 `LocalStore` + 44 处手工 `addListener`/`removeListener` |
| `LocalStore` 上帝类 | `lib/core/local_store.dart` | 903 行、约 35 个公开方法，单一 ChangeNotifier 同时承担站源开关/追剧/收藏/搜索历史/各类设置/观看进度/备份导入导出 |
| ~~`core` 反向依赖 `features`~~ | `lib/core/*`、`lib/widgets/*` | **已于 2026-10-26 由在途重构解决**：新增 `lib/data/media/` 层，`background_downloads`/`download_collections`/`media_exports`/`media_library`/`media_merge`/`media_merge_queue`/`media_pipeline`/`cover_decoder` 迁出 `features`/`widgets`，`video_enhancement_preferences` 迁入 `lib/core`。现 `core`/`data`/`widgets` 均不再 import 任何 `features`，依赖方向为 `features → data/media`。本行待该改动合入后删除 |
| `player` ↔ `downloads` 双向依赖 | `lib/features/` | `player_screen.dart` 与 `downloads_screen.dart` 互相 import。上一行的 `core`/`widgets` 反向依赖已清，这一组模块级双向仍在；建议抽出「本地媒体」接口层由两侧共同依赖 |
| `Config.CDNURL` 未被引用 | `native/core/app_runtime.go:42` | 全仓库零引用；配对的 `defaultCDNURL`（`config_defaults.go:5`）目前只被 `network_media_test.go` 一处断言 `c=` 用到，而生产代码中 **没有任何地方生成 `c=` 参数**。疑似 CDN 可配置特性未接线完成，**先确认意图再删**，勿当无主死代码清理。注：其余站源 URL 字段（`HuangdouURL`/`YeguoURL`/`DSDURL`/`SoraniURL`/`GuipianURL`/`HanxiaoquanURL` 等）均被 `provider_media.go:27` 的 `providerBaseURL` 使用——宿主侧封面请求的 Referer 与诊断日志站点标识依赖它们（见该函数 24-26 行注释），**有意保留**，不是遗留化石 |
| `Downloader` 命名误导 | `native/core/app_runtime.go` | 实为整个 app runtime，被 30+ 文件引用；`nativeDispatch` 为约 40 分支扁平 switch，`nativeInput` 是全体 action 的字段并集 |
| Dart 测试配比失衡 | `test/` | 21 文件 2940 行集中在 danmaku/follow/media_library；discovery(901)/player(1680)/sources(1050)/settings(971)/search(723) 几乎无覆盖 |
| `pubspec.lock` 可能已过期 | 仓库根 | 本地（Flutter 3.47.7 / Dart 3.13.5）`flutter pub get --enforce-lockfile` 直接失败，常规 `pub get` 会漂移 177 个包。CI 第 4 步就是 `--enforce-lockfile`，且该步从未加过 `continue-on-error`，**若 CI 所用的 3.47.4 同样不一致，则所有 CI run 都会在此变红**。需在与 CI 完全一致的 SDK 上复核后再决定是否重新 lock |
| `dart format` 结果依赖 SDK 版本 | `.github/workflows/build.yml` | CI 固定 Flutter 3.47.4；用 Dart 3.13.5 跑会报 46 个文件不合格式（列表字面量尾逗号规则变更）。勿在不升 SDK pin 的情况下用新版 SDK 重排格式 |
| 两种依赖注入风格并存 | 全局 | 路由新屏用 provider，老屏用构造参数 |
| `SourceSite` 仍保留 1+10 源静态元数据 | `lib/core/models.dart` | 作为旧数据兜底；运行期可用列表只含红果+已安装扩展 |
| LAN `user` 字段是常量 | `lan_controller.dart` | 多用户移除后固定为 `'本机用户'` |
| 视觉只完成前两批 | `app_theme.dart` + widgets | 播放器控件、设置页分组、榜单页尚未按 MD3E 重设计 |
| 扩展无签名 | `extensions-repo` | 信任官方仓库 HTTPS + SHA-256；如需强校验需重新设计发布链路 |

---

## 7. 常用命令

```bash
# 全量验证（提交前跑这三条）
dart analyze --fatal-infos lib test
flutter test --dart-define=DISABLE_REMOTE_IMAGES=true
cd native && go test -race ./...

# 只跑扩展 parity
cd native && go test -race -run "ExtensionParity" ./core/ -v

# 校验扩展与生成索引
cd extensions-repo
python3 tools/build.py --check
python3 tools/build.py --base-url https://raw.githubusercontent.com/OWNER/REPO/main/extensions

# 原生核心构建（改 Go 后必须先跑）
python3 scripts/build_native.py --platform android --abi arm64-v8a
python3 scripts/build_native.py --platform darwin   # universal dylib
python3 scripts/build_native.py --platform linux    # 需在 Linux 上执行
```

---

## 8. 踩过的坑

1. **goja 无 WHATWG API**：`new URL()`、`URLSearchParams` 不存在，必须用 `hg.url.parse` / `hg.url.encodeQuery`。
2. **goja 宿主函数签名**：必须 `func(goja.FunctionCall) goja.Value`。
3. **goja Interrupt 后 VM 不可复用**：`ext.Extension.call` 已自动重建 runtime。
4. **part extension 不能调 `setState`**：播放器拆分时踩过。
5. **Dart 超时必须长于 Go**：否则 Dart 先超时，Go 任务仍在跑。
6. **`publicBytes` 是下划线字节码**：野果 key/iv 形如 `97_98_99`，不是 hex。
7. **测试 fixture 要动态注入 host**：写死域名会打到真实站点。
8. **扩展脚本文件名必须等于头部的 `@id`**：`build.py` 与 Go 安装器都会校验。
9. **扩展文件头必须完整**：缺少 `==/HongguoExtension==` 结束标记会拒绝安装。
10. **`extensions-repo/extensions/` 同时是 Flutter asset**：新增/重命名扩展后确认 `pubspec.yaml` 的 asset 目录仍包含文件。

---

## 9. 下一步建议（按优先级）

1. **先确认 CI 能不能跑起来**（新晋最高优先）：在与 CI 一致的 Flutter 3.47.4 上验证两件事——
   - `flutter pub get --enforce-lockfile` 是否通过。该步从未加 `continue-on-error`，若 fail 则 CI 第 4 步就红，后面全白搭。
   - `dart format` 与 `flutter test` 是否真的为绿。这两项此前长期 `continue-on-error`，**无人知道它们的真实状态**；现已改为阻塞，首次手动跑 CI 有可能暴露历史遗留失败（注意 format 结论依赖 SDK 版本，勿用 Dart 3.13.x 的結果判断）。
2. **发布前置**：推官方扩展仓库、替换 `extensionIndexURL`（CI 阻塞已于 2026-10-26 完成）。
3. **真机验收**：全新安装只有红果、随包扩展手动安装/更新/卸载、受限源默认关闭。
4. **砍 `core`/`widgets` → `features` 的反向依赖**：共 4 处 import（`core_bridge.dart` 2 处 → `downloads`、`core/playback_preferences.dart` 1 处 → `player`、`widgets/cover_decoder.dart` 1 处 → `downloads`），改动面小、边界清晰，是让 `core` 真正成为底座的前提。另有一组 `player` ↔ `downloads` 模块级双向 import 需一并断开。
5. **清理 `native/core/app_runtime.go`**：仅限确认过的项——见第 6 节 `Config.CDNURL`。**不要**删除其余站源 URL 字段，`providerBaseURL` 在用。`Downloader` 建议更名为 `Runtime`（跨 30+ 文件，可先用类型别名过渡减少扩散）。
6. **补齐高风险屏幕的 widget 测试**：优先级低于第 4、5 项，但在 discovery/player/sources/settings 各有真实崩溃风险。
7. **player_screen Controller 化**：把状态机从 State 类抽到 `PlayerController`。
8. **视觉第三批**：播放器控件与设置页分组（用户感知最强）。
9. **可选清理**：把 `SourceSite` 的静态元数据进一步收敛为仅用于旧数据展示，完全由扩展清单驱动。

---

## 10. 相关文档

- `README.md` —— 用户向功能说明与构建流程
- `CHANGELOG.md` —— 版本历史
- `extensions-repo/README.md` —— 单文件扩展开发规范、文件头字段与索引生成
