# 红果鉴 v0.3 交接文档

> 更新时间：2026-10-27 ｜ 版本 `0.3.0+89` ｜ 分支 `main`
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
| `flutter test --dart-define=DISABLE_REMOTE_IMAGES=true` | ✅ 157 个测试全绿（墙钟约 16s） |
| 扩展校验 `python3 tools/build.py --check` | ✅ 10 个扩展全部通过 |
| `gofmt -l native` | ✅ 干净 |
| macOS `scripts/build_macos.py` | ✅ universal app 构建并启动，首页/韩小圈目录/分集/HLS 播放通过 |
| Linux `scripts/build_linux.py` | ✅ x64 工程/脚本/CI 已接入；arm64 待 FFmpegKit 上游支持；待 Linux 实机验证 |
| NativeChannel FFI 响应 | ✅ 修复 worker 回传 record 被父 isolate 丢弃导致 initialize 永久等待 |
| Riverpod 启动容器 | ✅ 启动依赖一次性注入，移除非法的 updateOverrides 新增 override |

### 2.1 2026-10-27 插件系统加固（本轮）

| 问题 | 修复 |
| --- | --- |
| 跨扩展并发共享 `Registry.callCtx` → 数据竞争（`-race` 可复现） | context 归每个 `gojaRuntime` 所有；新增 `TestConcurrentExtensionsDoNotShareCallContext` |
| 无 deadline 的脚本调用可被死循环永久持锁 | `Extension.call` 加 20s 硬看门狗；`ValidCategory` 用 3s 有界 ctx；新增 `TestScriptCallWatchdogInterruptsLoop` |
| `SupportsOnlineSearch` 恒返回 true，与清单声明矛盾 | 改由 manifest 驱动；`toleratesEmptyCatalog` 改为按分类判定 |
| 扩展 fetch 可访问 127.0.0.1 / 私网（含 3xx 绕过） | `validateExtensionAddress` + 重定向复核；测试用 `allowLocalExtensionHost` 显式豁免 |
| `resolve` 契约的 `headers` 被静默丢弃、`qualities` 无从实现 | `headers` 全链路生效（播放/下载/HLS），传输层头由宿主独占；`qualities` 从契约与文档移除 |
| 扩展记录持久化用内置源白名单过滤 | 改为 ID 形态校验，第三方扩展的计数/更新时间/保存待办不再丢失 |
| `hg.storage` 每次读写都落盘（黄豆每个响应写一次） | 进程内缓存 + 值未变不写盘；卸载时清理 |
| 扩展日志写进诊断文件但 UI 不可见 | `DiaryService` 收录 `extension_log`；站源页新增「扩展日志」面板 |
| 远端扩展索引从未被调用（"不发版修源"无法兑现） | `SourcesViewModel` 合并远端索引，展示可更新/已下架，安装支持 URL + SHA-256 回落 |

### 2.2 2026-10-27 能力声明化（第二轮）

| 问题 | 修复 |
| --- | --- |
| 22 处 Dart 硬编码源 ID（VIP 过滤、弹幕开关、详情提示、补资料） | 清单新增 `@vip` / `@danmaku` / `@detailFields`；`SourceSite` 暴露 `vip`/`danmaku`/`detailFields`，UI 全部改为读声明 |
| Go 侧补资料规则按源 ID 硬编码（红果 / 黄豆） | `nativeNeedsExtraMetadata` 由 `detailFields` 驱动；`nativeExtraMetadata` 不再按源分叉，统一走 `provider.Detail` |
| VIP 能力判断散落在 `sourceStatus`/`sourceJob`/`vipMetadata` | 统一为 `sourceSupportsVIP` / `sourceDeclaresDetailField` |
| 第三方扩展声明的榜单被 Dart 侧拒绝 | 榜单归属改由 Go 的 `findRankingBoard` 权威校验；删除 `RankingBoard.sourceForID` 的硬编码映射表 |
| `hg.storage.baseURL` 镜像钩子只读不写（文档承诺、界面缺失） | 新增 `sourceSettings` / `saveSourceSetting` 两个 action + 站源页通用设置表单；写入校验 http(s) 与私网拦截 |
| 扩展清单新字段无工具校验 | `build.py` 校验 `vip`/`danmaku`/`detailFields`（取值、去重、数量上限），`index.json` 已重新生成 |

本轮新增测试：`TestManifestCapabilities`、`TestSourceSettingsRoundTrip`、
`TestSourceSettingsRejectsInvalidValues`、`TestNativeNeedsExtraMetadataFollowsManifest`、
`TestSourceSupportsVIPFollowsManifest`。

### 2.3 2026-10-27 写盘与播放器（第三轮）

| 问题 | 修复 |
| --- | --- |
| `saveWatch` 每次提交后 `load()` 全量重解析 history/favorites/followStates | 改为就地更新内存缓存；`load()` 只留给真正的重载场景（清空历史、LAN 合并、恢复备份） |
| 播放时每 5 秒无条件落盘，300 条历史整体编码 | 心跳降到 15 秒；`PlaybackProgressController` 内再加节流（15 秒或前进 5 秒才写），暂停/退出/切集走 flush 不受限制 |
| 切集后会沿用上一集的节流窗口 | `markOpened` / `beginEpisode` 重置节流基准 |
| 播放器 State 混着画中画状态机与平台通道 | 抽出 `PictureInPictureController`：状态迁移、平台调用、700ms 退出宽限与 2s 确认超时都在控制器内，屏幕只保留「可见性变化后如何暂停/刷新」这些依赖播放器实例的副作用 |

新增测试：`test/picture_in_picture_controller_test.dart`（5 项）、
`playback_progress_controller_test.dart` 的 `throttling` 组（3 项）。

**注意**：`follow_updater_test.dart` 与 `playback_recovery_scheduler_test.dart` 是时序敏感的
偶发失败（单跑必过、全量跑偶发红），与上述改动无关——在改动前的干净树上也复现过。
若 CI 出现这两项，重跑即可，不要当成回归。

### 2.4 2026-10-27 Riverpod 分领域订阅（第四轮）

| 问题 | 修复 |
| --- | --- |
| Riverpod 只作 DI，真实状态在 `LocalStore` 单个 ChangeNotifier 上 | `LocalStore` 新增 `libraryRevision` / `settingsRevision` / `accessRevision` 三个单调计数，`_commit` 按变更键递增 |
| 详情页、下载页监听整个 store，任何写入都整屏 `setState` | 两屏改为只比较「库 + 准入」两个修订号，设置类变化不再触发重建 |
| provider 层无细粒度入口 | 新增 `libraryRevisionProvider` 等三个 `NotifierProvider`，以及 `availableSourcesProvider` / `favoritesProvider` / `followStatesProvider` |

**关键坑**：不能写成

```dart
final xProvider = Provider<int>((ref) {
  final store = ref.watch(storeProvider);   // ← 永远不会重算
  return store.someRevision;
});
```

`ChangeNotifierProvider` 的 `notifyListeners` 只调用 `ref.notifyListeners()`，
不会改变 provider 的 state 实例，因此 `ref.watch(storeProvider)` 的下游不会失效。
必须用 `ref.listen(storeProvider, ...)` 显式接收通知——`StoreRevisionNotifier`
就是这么实现的（`lib/core/providers.dart`）。

新增测试：`test/store_providers_test.dart`（5 项，覆盖三类领域隔离 +
`availableSources` 不被进度写入波及 + 收藏列表更新）。

### 2.5 2026-10-27 扩展仓库接线、路由收口、设置 schema（第五轮）

| 问题 | 修复 |
| --- | --- |
| `extensionIndexURL` 硬编码，换地址要改 Go 并重编 | 改为 `-ldflags -X` 可覆盖；`scripts/app_build.py` 读 `HONGGUO_EXTENSION_INDEX_URL` 注入，`build_native.py` / `build_ios.py` 自动透传 |
| 占位地址不可达，每次进站源页都等一次超时 | 命中占位值时 `RemoteIndex` 直接返回空并标记 `unconfigured`，不发请求；站源页显示「此版本未配置在线仓库」 |
| 路由里 15×2 处重复 `ref.read(...)` | 抽出 `AppDeps` + `_deps(ref, withLan/withLibrary)`，每个 builder 只取一次 |
| 每源设置只有宿主硬编码的镜像地址 | 扩展可用 `@settings` 声明 input / toggle / choice 三类设置项，宿主渲染通用表单，值存进该源 `hg.storage`；`build.py` 与 Go 侧双重校验 |

**`@settings` 语法**（多项用 `;` 分隔，字段用 `|` 分隔）：

```
// @settings useProxy|使用代理|toggle|false
// @settings quality|画质偏好|choice|auto|auto=自动|1080=1080P
// @settings pageSize|每页数量|choice|24|24=24 条|48=48 条
```

字段顺序 `key|title|type|default|其余`：`input`/`toggle` 的第 5 段是 placeholder，
`choice` 的第 5 段起全是选项。**choice 没有 placeholder**——两者共用一段会让
`24|24=24 条|...` 把第一个选项当成 placeholder 吃掉（实现中踩过）。

青空已声明 `pageSize` 作为示例，扩展侧用 `hg.storage.get('pageSize')` 读取。

**发布步骤**（唯一还需要外部动作的一项）：

```bash
cd extensions-repo
python3 tools/prepare_release.py --repo OWNER/REPO   # 生成索引 + 初始化仓库
# 按脚本输出的提示创建 GitHub 仓库、push，然后构建时：
export HONGGUO_EXTENSION_INDEX_URL=https://raw.githubusercontent.com/OWNER/REPO/main/index.json
```

### 2.6 2026-10-27 发现页与播放页 widget 测试（第六轮）

此前 `discovery(901 行)` 与 `player(1425 行)` 各只有一条 smoke 测试。本轮补 21 项。

| 文件 | 覆盖 |
| --- | --- |
| `test/discovery_screen_test.dart`（7 项） | 首屏加载、加载失败、受限源默认关闭、切源、分页滚动、VIP 过滤的分组前提、全部站源关闭时的空态 |
| `test/player_menu_test.dart`（9 项） | 选集总数与分集格子、点击回调下标、倍速写回偏好、清晰度档位与当前值、本地播放的说明行、弹幕开关的出没、弹幕失败状态、追剧按钮文案、自动连播状态 |
| `test/playback_launch_screen_test.dart`（5 项） | 加载态、详情失败 + 重试、无分集提示、单集不越界、正常进入播放路由 |

**关键约束：`PlayerScreen` 无法在 flutter_test 里构造。** media_kit 的 `Player`
会加载原生 libmpv，测试环境直接抛 `Cannot find Mpv.framework`。因此播放页的
测试策略是分两层：

- 状态机与会话逻辑 → `player_session_controller_test.dart`（已有，用假 `PlayerPlaybackHost`）；
- 菜单与启动页 → 不接触 `Player`，可完整驱动（本轮新增）。

`PlayerControls`（1085 行）仍无法测试：它的每个字段都直接读 `widget.player.state`
并订阅 `player.stream`。要覆盖它需要先引入 `PlayerPlaybackHost` 那样的抽象，
属于独立改动。

**顺带修复的真实缺陷**：`_CachedCoverImageState._start` 把
`_CoverRequests.run(...)` 的 Future 交给 `FutureBuilder` 后没有挂错误处理器，
封面请求失败（离线、站点拒绝）会变成未捕获异步异常——测试里表现为
"测试结束后抛错"，生产里污染日志。已加 `unawaited(file.catchError(...))`。

**测试里的两个环境依赖**，写新测试时容易踩：

1. 任何会 `pushReplacement('/player')` 的页面必须挂在 `GoRouter` 下，否则会以
   `No GoRouter found in context` 走错误分支，掩盖真实行为；
2. `FixtureRepository.cover` 默认抛异常，卡片在 150ms 后请求封面，未处理会
   让测试失败在"与断言无关"的地方。

### 2.7 2026-10-27 插件范式优化（第七轮）

审阅 10 个扩展共 175 个自定义函数后，发现通用机制下沉不足：同名函数复制后各自漂移。

| 问题 | 修复 |
| --- | --- |
| `integer()` 有 7 个版本，语义不一致（dsd 正则允许负号又拒绝负数、huangdou 兼容 number 类型） | 全部改用 `source.int`，删除 7 处重复实现；顺带修复 `Number('')===0` 导致「字段缺失被当成 0」的缺陷 |
| 鬼片与韩小圈的 `resolve` 逐字相同（`var now="<m3u8>"` + 兜底直链正则） | 新增 `source.macPlaylist`，两处各减 18 行 |
| 6 个源各写一份 `parseCards`（遍历/去重/取封面/限 500 同构） | 新增 `source.cards`，扩展只声明选择器与字段位置；已迁移鬼片、韩小圈、黄果视频 |
| `function base(ctx) { return source.base(ctx); }` 5 处纯别名 | 随上述迁移一并消除 |

**`source.cards` 的字段声明**支持四种取值：`'attr:title'`（节点属性）、
`'.sel'`（子节点文本）、`'.sel@attr'`（子节点属性）、`/regex/`（HTML 片段正则）、
函数（自定义）。去重、上限、封面校验、相对地址解析由宿主保证。

实现中踩到的两点：

1. **window 必须对选择器型字段同样生效**。最初只在正则分支截断，`cover` 仍能读到
   窗口外的 `img`，等于 window 形同虚设。现改为在截断片段内重新解析。
2. **`allowEmptyTitle`**。黄果视频的卡片可能只有图片没有标题，原先靠宿主
   DisplayTitle 兜底；`cards` 默认要求标题（避免把导航链接当剧集），该站显式放开。

**明确不做**：`dramaFromMap`（野果固定字段 / 黄果 AI 多候选字段 + 标题修复 /
帝果无此函数）反映的是各站 API 字段命名差异，属"站点差异"而非通用机制，
强行统一只会把差异藏进配置。同理 cloudfront 的 198 行签名、dsd 的 160 行
aaencode 解码器也不下沉——下沉意味着站点改协议就要发版。

### 2.8 2026-10-27 hgkit 分层拆分（第八轮）

`kit.js` 在上一轮增至 539 行、单文件挂 20 多个 helper，新增能力时改动面与
评审成本都过高。按职责拆成 5 层 + 装配层：

| 文件 | 行数 |
| --- | --- |
| `kit-core.js` | 97 |
| `kit-html.js` | 171 |
| `kit-normalize.js` | 117 |
| `kit-net.js` | 80 |
| `kit-maccms.js` | 30 |
| `kit.js`（装配） | 123 |

注入顺序即依赖顺序，由 `native/ext/kit.go` 的 `hostKitSources` 定义；
`goja_runtime.go` 逐层 `Compile` + `RunProgram`，文件名保留在报错信息里。

**关键验证**：

- 10 个扩展的 parity 测试全部通过，行为零变化；
- 新增 `TestHostKitLayerOrder`：逐层加载并断言 21 个公开面齐全。若有人在
  `kit-core` 里引用上层能力，测试会立即失败（实测缺前置层时报
  `Cannot destructure property 'text' of 'kit'`，不会静默降级）；
- `hostKitSource()` 保留为测试/诊断用的拼接视图。

### 2.9 2026-10-27 PlayerSurface 抽象（第九轮）

`PlayerControls`（1085 行）与 `PlayerInteractions` 此前直接依赖 media_kit 的
`Player`，而 `Player` 构造时要加载原生 libmpv，在 flutter_test 里抛
`Cannot find Mpv.framework`——控件层因此完全没有测试覆盖。

| 改动 | 说明 |
| --- | --- |
| 新增 `player_surface.dart` | `PlayerSurface` 接口：6 个状态流 + 7 个状态字段 + 5 个命令 |
| `MediaKitPlayerSurface` | 生产环境唯一实现，是 `Player` 出现的最后边界 |
| `PlayerControls` / `PlayerInteractions` | 全部改为依赖 `PlayerSurface`，不再 import media_kit |
| `PlayerScreen` | 构造 `MediaKitPlayerSurface` 并注入，`_player` 仍由播放器本体持有 |

**刻意保持窄**：只声明控件与手势实际用到的能力。播放列表、音轨、截图等
完整能力不进抽象，避免它随 media_kit 一起膨胀。

新增 `test/player_controls_test.dart`（7 项）：图标随播放状态切换、播放按钮
回调宿主而非直接操作播放器、禁用态不响应、倍速/画质标签、弹幕按钮出没、
进度流驱动刷新、拖动走 `onSeek` 回调。

**测试里的两个注意点**：

1. 流事件需要两次 `pump()`——第一次送达监听器，第二次应用 `setState` 的重建；
2. 控件在播放中会淡出（`_visible || !playing || buffering || panelOpen`），
   但节点仍在树里，因此断言用 `ValueKey` 定位图标、用 `Slider.value` 判断
   进度，而不是依赖可见性或时间文案格式。

### 2.10 两项评估后放弃（附实测依据）

| 项 | 结论 |
| --- | --- |
| 历史记录增量存储 | 实测 300 条历史编码一次约 **1.9ms**、载荷约 118KB。心跳已降到 15 秒且带节流，这点 CPU 开销可忽略；真正的成本（SharedPreferences 整文件重写）已被节流挡住。改按键增量会牵动 LAN 合并、备份格式与清空逻辑，风险明显大于收益，**不做** |
| 播放器面板与菜单抽取 | 菜单已全部委托给 `PlayerMenu`（357 行独立文件）；`_openPanel` 剩下的只有 `_panelOpen` 赋值、`showDialog` 生命周期与焦点恢复。`_panelOpen` 是被 8 处 UI 条件读取的布尔标志，抽成控制器只增加一层间接、不解决任何问题，**不做** |

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

- **随包手动安装**：`lib/features/sources/sources_view_model.dart` 读取 `extensions-repo/index.json`，用户点击安装时从 `extensions-repo/extensions/<id>.js`（pubspec asset）读取脚本，经 `installExtension(..., code: ...)` 写入 Go 数据目录；应用启动时不自动安装任何扩展。
- **远端索引**：`loadExtensions()` 在随包索引之上合并 `extensionIndex()`（Go 侧 `RemoteIndex`），远端条目提供版本、更新标记与 `killSwitch`。随包脚本仍优先（离线可用），远端条目才回落到 `url + sha256` 下载并校验摘要。拉取失败静默沿用随包结果，不打断站源页。
- **本地/内置路径**：`nativeInput.ExtensionCode` 直接接收脚本内容；`ExtensionURL` 与 `ExtensionCode` 二选一。
- **不再签名**：旧 zip + ed25519 公钥链路已删除。信任模型为官方仓库 HTTPS + SHA-256，请只安装可信来源的扩展。
- **官网仓库**：`extensions-repo/` 需推为独立 GitHub 仓库；`extensionIndexURL` 仍是占位地址，正式发布前替换为真实地址（代码链路已接通，缺的只是真实地址）。

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

### 4.5 宿主工具库 `hgkit`（`native/ext/kit-*.js`，按层注入）

每个扩展运行前注入 `globalThis.hgkit`，把通用机制沉到宿主。

**分层**（`native/ext/kit.go` 的 `hostKitSources` 定义注入顺序，后者依赖前者）：

| 文件 | 行数 | 职责 |
| --- | --- | --- |
| `kit-core.js` | 97 | 建立命名空间；`text/trimBase/int/pick/first/rawPick/unescapeHTML/cleanText/labelOf` |
| `kit-html.js` | 171 | URL 归一、媒体/封面校验、`metaContent`、`cards` 列表解析 |
| `kit-normalize.js` | 117 | `tags`、`page`、`chapters`、`drama` 字段映射 |
| `kit-net.js` | 80 | `fetchText/fetchJSON`（走宿主网络栈）、`cloudFrontCredentials` |
| `kit-maccms.js` | 30 | 苹果 CMS 播放页取流 `extractMacMedia` |
| `kit.js` | 123 | `defineSource` 装配与默认实现 |

各层用 `const {text, int} = kit` 引入下层能力，函数体保持原样。
`TestHostKitLayerOrder` 逐层加载并断言公开面齐全——若有人在 `kit-core` 里
引用上层能力，该测试会直接失败，而不是等扩展运行期才出现 undefined。



- `hgkit.defineSource`：补默认 `validCategory`（基于 `categories`）与 `resolve`（直接媒体地址），并挂载 helper。
- `source.getText/getJSON`：宿主网络栈、自动 base/Referer、状态码校验。
- `source.clean/text/pick/first/int/tags/url/mediaURL/isMediaURL/cover/meta`：清洗、字段与 URL/DOM 归一。
- `source.page/chapters/drama`：统一分页、分集去重排序、剧集字段映射。
- `source.cards`：列表页卡片解析（去重、上限、封面校验由宿主保证，扩展只声明选择器）。
- `source.macPlaylist`：苹果 CMS 播放页取流（`var now="<m3u8>"` 或首个直链）。
- `source.int`：非负整数解析；空值/负数/超限/非数字一律 `null`（修复了 `Number('')===0` 把缺失当 0 的问题）。
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

1. **官方扩展仓库**：将 `extensions-repo/` 推为独立 GitHub 仓库。一条命令完成本地准备：
   ```bash
   cd extensions-repo && python3 tools/prepare_release.py --repo OWNER/REPO
   ```
   然后按脚本提示创建仓库并 push。**不再需要改代码**：构建时用
   `export HONGGUO_EXTENSION_INDEX_URL=<索引地址>` 注入即可。客户端链路（远端索引
   合并、可更新/已下架标记、URL + SHA-256 安装）已全部接通；未设置该变量时
   行为等同纯随包安装，且不会因占位地址发请求等超时。
2. ~~**CI 检查不阻塞**~~ **已于 2026-10-26 修复**：`checks` job 已移除全部 `continue-on-error`（原目标 7 处，其中 TG 推送 1 处保留为非阻塞——发布已完成，通知失败不应回滚 Release）；同时修复了 `dart analyze` / `go test` 两段重复 YAML 键。五个平台 job 由 `needs: prepare` 改为 `needs: [checks, prepare]`，analysis 不再先白烧五平台产物再失败。`checks` 超时由 20 分钟放宽到 30 分钟，避免冷缓存编译慢被误判成代码缺陷。
3. **真机验证手动安装**：Android / Windows / macOS / Linux 各跑一次全新安装，确认首启只有红果，随包扩展需手动安装，受限源默认关闭。
4. **更新扩展验证**：安装/更新/卸载、离线打开站源管理页各验证一次；远端索引可用后，再验证「可更新 → 更新」「已下架 → 卸载」两条路径。
5. **macOS 公证**：当前构建为 ad-hoc 签名，正式分发需 Developer ID 签名与公证，否则用户首次打开需右键「打开」。

---

## 6. 已知技术债

| 债务 | 位置 | 说明 |
| --- | --- | --- |
| `player_screen.dart` 1425 行 | `lib/features/player/` | 该目录已有 25 个文件，会话/进度/健康/恢复/画中画/交互均已独立成控制器；`_PlayerScreenState` 剩下的主要是**装配与接线**（构造各控制器、把回调接到播放器实例）。真正的面板生命周期仍与 State 绑定，进一步拆分收益递减；如要继续，优先抽的是「面板与菜单」而不是状态机 |
| `discovery_screen.dart` 901 行 | `lib/features/home/` | 已由原 `home_screen.dart` 更名并瘦身；导航壳与内容区仍未彻底分离 |
| ~~路由未用 StatefulShellRoute~~ | `lib/app/router.dart` | **已解决**：`router.dart:55` 现为 `StatefulShellRoute.indexedStack`，三个分支各自保留状态；本行待下次清理时删除 |
| ~~Riverpod 只作 DI、未作状态管理~~ | `lib/core/providers.dart` | **已于 2026-10-27 改善**：新增分领域 revision 与 3 个领域级 provider，详情/下载页改为按领域订阅。仍保留的 `addListener` 多数是控制器之间、滚动、焦点的合理用途 |
| `LocalStore` 上帝类 | `lib/core/local_store.dart` | 903 行、约 35 个公开方法，单一 ChangeNotifier 同时承担站源开关/追剧/收藏/搜索历史/各类设置/观看进度/备份导入导出 |
| ~~`core` 反向依赖 `features`~~ | `lib/core/*`、`lib/widgets/*` | **已于 2026-10-26 由在途重构解决**：新增 `lib/data/media/` 层，`background_downloads`/`download_collections`/`media_exports`/`media_library`/`media_merge`/`media_merge_queue`/`media_pipeline`/`cover_decoder` 迁出 `features`/`widgets`，`video_enhancement_preferences` 迁入 `lib/core`。现 `core`/`data`/`widgets` 均不再 import 任何 `features`，依赖方向为 `features → data/media`。本行待该改动合入后删除 |
| `player` ↔ `downloads` 双向依赖 | `lib/features/` | `player_screen.dart` 与 `downloads_screen.dart` 互相 import。上一行的 `core`/`widgets` 反向依赖已清，这一组模块级双向仍在；建议抽出「本地媒体」接口层由两侧共同依赖 |
| `Config.CDNURL` 未被引用 | `native/core/app_runtime.go:42` | 全仓库零引用；配对的 `defaultCDNURL`（`config_defaults.go:5`）目前只被 `network_media_test.go` 一处断言 `c=` 用到，而生产代码中 **没有任何地方生成 `c=` 参数**。疑似 CDN 可配置特性未接线完成，**先确认意图再删**，勿当无主死代码清理。注：其余站源 URL 字段（`HuangdouURL`/`YeguoURL`/`DSDURL`/`SoraniURL`/`GuipianURL`/`HanxiaoquanURL` 等）均被 `provider_media.go:27` 的 `providerBaseURL` 使用——宿主侧封面请求的 Referer 与诊断日志站点标识依赖它们（见该函数 24-26 行注释），**有意保留**，不是遗留化石 |
| `Downloader` 命名误导 | `native/core/app_runtime.go` | 实为整个 app runtime，被 30+ 文件引用；`nativeDispatch` 为约 40 分支扁平 switch，`nativeInput` 是全体 action 的字段并集 |
| Dart 测试配比 | `test/` | **2026-10-27 已补齐 discovery / player 菜单 / 播放启动页**（38 文件 4962 行）。仍缺：`PlayerControls`（1085 行，需先抽象 `PlayerPlaybackHost` 式的播放器接口）、`sources`(1050)/`settings`(971)/`search`(723) 的交互级覆盖 |
| `pubspec.lock` 可能已过期 | 仓库根 | 本地（Flutter 3.47.7 / Dart 3.13.5）`flutter pub get --enforce-lockfile` 直接失败，常规 `pub get` 会漂移 177 个包。CI 第 4 步就是 `--enforce-lockfile`，且该步从未加过 `continue-on-error`，**若 CI 所用的 3.47.4 同样不一致，则所有 CI run 都会在此变红**。需在与 CI 完全一致的 SDK 上复核后再决定是否重新 lock |
| `dart format` 结果依赖 SDK 版本 | `.github/workflows/build.yml` | CI 固定 Flutter 3.47.4；用 Dart 3.13.5 跑会报 46 个文件不合格式（列表字面量尾逗号规则变更）。勿在不升 SDK pin 的情况下用新版 SDK 重排格式 |
| 两种依赖注入风格并存 | 全局 | 路由新屏用 provider，老屏用构造参数 |
| `SourceSite` 仍保留 1+10 源静态元数据 | `lib/core/models.dart` | 作为旧数据兜底；运行期可用列表只含红果+已安装扩展 |
| LAN `user` 字段是常量 | `lan_controller.dart` | 多用户移除后固定为 `'本机用户'` |
| 视觉只完成前两批 | `app_theme.dart` + widgets | 播放器控件、设置页分组、榜单页尚未按 MD3E 重设计 |
| 扩展无签名 | `extensions-repo` | 信任官方仓库 HTTPS + SHA-256；如需强校验需重新设计发布链路 |
| ~~扩展能力多处在 Dart 硬编码~~ | `lib/features/**` | **已于 2026-10-27 解决**：`@vip`/`@danmaku`/`@detailFields` 进清单，UI 只读 `SourceSite`；`RankingBoard.sourceForID` 已删除，榜单归属由 Go 权威校验。仍保留的少量 `'huangdou'` 判断是 `Drama.fromJson` 的旧数据兼容（metadataSchema 迁移），属有意保留 |
| ~~无每源设置 UI~~ | `native/ext` + 站源页 | **已于 2026-10-27 解决**：`sourceSettings` / `saveSourceSetting` 两个 action + 站源页通用表单，镜像地址（`baseURL`）有写入入口与校验 |
| 路由仍重复 `ref.read` 同一依赖 | `lib/app/router.dart` | 15 处 `ref.read(storeProvider)` / `ref.read(repositoryProvider)`。改造成本会牵动 15 个屏幕的构造参数，收益仅减样板，本轮未动 |
| ~~进度写盘放大~~ | `playback_progress_controller.dart` + `library_store.dart` | **已于 2026-10-27 改善**：心跳 5s→15s、控制器内节流、提交后不再 `load()`。仍存在的是「300 条历史整体编码」——历史目前是单个 JSON 数组，要彻底消除需要改成按键增量存储（会影响 LAN 合并与备份格式），属于独立改动 |
| 每源设置仅一项 | `native/core/app_source_settings.go` | 目前只有镜像地址。扩展若需要更多可配置项（如并发数、画质偏好），需要把 schema 声明搬进清单（`@settings`）而不是宿主硬编码 |

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
11. **调用状态不能放在共享的 `Registry` 上**：一个 `Registry` 服务所有扩展，任何可写字段都会在跨源并发时互相覆盖（曾导致 `hg.fetch` 拿到别的源的 context，`-race` 可复现）。调用 context 属于每个 `gojaRuntime`。
12. **宿主回调必须有 deadline**：`Extension.call` 靠 `ctx.Done()` 触发 `vm.Interrupt`；传 `context.Background()` 等于放弃中断，死循环脚本会永久持有该源的执行锁。
13. **能力标志要在宿主侧生效，不能只回传给 UI**：`SupportsOnlineSearch` 恒 true 时，声明"不支持搜索"的扩展仍会被路由到 `catalog(query=...)` 并抛错。
14. **契约字段要么实现要么删掉**：`resolve.headers` 曾被解析后丢弃，比不提供更糟——扩展作者按文档写会静默失效。
15. **测试 fixture 需要显式豁免**：扩展的本机/私网拦截会让 httptest 合成站点失败，测试引擎用 `allowLocalExtensionHost` 打开，生产路径永远为 false。
16. **清单新增字段要三处同步**：`native/ext/manifest.go`（解析 + `Validate`）、`build.py`（`FIELD_MAP` + 校验）、`extensions-repo/README.md`（文档）。漏掉 build.py 会导致 CI 生成索引时字段被静默丢弃。
17. **`detailFields` 一律小写比较**：`ParseScript` 会把声明统一转小写，所以宿主侧 `switch` 与 Dart 侧 `switch` 都必须用 `onlinedate`/`releasestatus`，不是驼峰。

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

### 9.1 仍未做（按 ROI）

1. **推官方扩展仓库**：唯一需要外部动作的一项。本地准备已脚本化
   （`tools/prepare_release.py`），构建侧也不再需要改代码（`HONGGUO_EXTENSION_INDEX_URL`）。
2. ~~`PlayerControls` 的接口抽象~~ **已于 2026-10-27 解决**：见 2.9，
   控件层已脱离 media_kit 并有 7 项 widget 测试。
3. **`pubspec.lock` 与 CI SDK 一致性**：需在与 CI 完全一致的 Flutter 3.47.4 上复核
   `--enforce-lockfile`，否则 CI 可能在这一步就红。

> 评估后主动放弃（附实测依据，见 2.10）：历史记录增量存储、播放器面板抽取。
>
> 已于 2026-10-27 完成，原列在此处：每源设置 UI（镜像写入入口）、能力声明搬进 manifest、
> `hg.storage.baseURL` 钩子接通、`player_screen` 状态机 Controller 化、进度写盘去抖、
> Riverpod 分领域订阅、路由依赖注入收口、每源设置 schema 化、扩展索引地址可配置、
> discovery / player 菜单 / 播放启动页的 widget 测试、hgkit 分层拆分、PlayerSurface 抽象。

---

## 10. 相关文档

- `README.md` —— 用户向功能说明与构建流程
- `CHANGELOG.md` —— 版本历史
- `extensions-repo/README.md` —— 单文件扩展开发规范、文件头字段与索引生成
